import Foundation
import Combine
import AVFoundation
import ApplicationServices
import AppKit

@MainActor
final class PermissionManager: ObservableObject {

    @Published var hasMicrophonePermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false

    /// Called when PermissionManager needs to surface an unsolvable error toast.
    /// AppDelegate wires this to `AppDelegate.showErrorToast(title:body:)`.
    /// Title/body match DESIGN.md toast copy conventions.
    var onToastError: ((_ title: String, _ body: String) -> Void)?
    /// Called to show a persistent (non-auto-dismissing) toast. Used for the
    /// restart-required notification. Wired by AppDelegate to
    /// `errorToastWindow?.show(title:body:persistent:true)`. P2 finding #3.
    var onShowPersistentToast: ((_ title: String, _ body: String) -> Void)?
    /// Called with no arguments to hide an active persistent toast when the
    /// accessibility-grant watcher triggers a restart. Wired by AppDelegate to
    /// `errorToastWindow?.hide()`. P2 finding #3.
    var onHideToast: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    
    init() {
        checkAllPermissions()
    }
    
    func checkAllPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    func refreshPermissions() {
        refreshTask?.cancel()
        checkAllPermissions()
        AppLog.permissions.notice("Refreshing permission state")

        refreshTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [250_000_000, 750_000_000, 1_500_000_000]

            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)

                guard let self, !Task.isCancelled else { return }
                self.checkAllPermissions()
            }
        }
    }

    func requestInitialPermissionsIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AppLog.permissions.notice("Requesting initial microphone access")
            requestMicrophonePermission()
        } else {
            refreshPermissions()
        }

        if !hasAccessibilityPermission {
            AppLog.permissions.notice("Requesting initial accessibility access")
            requestAccessibilityPermission(prompt: true)
        }
    }
    
    private func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            hasMicrophonePermission = false
        case .denied, .restricted:
            hasMicrophonePermission = false
        @unknown default:
            hasMicrophonePermission = false
        }
    }
    
    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .authorized:
            hasMicrophonePermission = true
            AppLog.permissions.notice("Microphone permission is granted")
            refreshPermissions()
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.hasMicrophonePermission = granted
                    AppLog.permissions.notice("Microphone permission updated: \(granted, privacy: .public)")
                    self?.refreshPermissions()
                }
            }
            
        case .denied, .restricted:
            hasMicrophonePermission = false
            AppLog.permissions.error("Microphone permission is unavailable")
            openMicrophoneSettings()
            
        @unknown default:
            hasMicrophonePermission = false
        }
    }
    
    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermission(prompt: Bool = true) {
        // First check current status without prompting
        let checkOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let currentlyTrusted = AXIsProcessTrustedWithOptions(checkOptions)
        
        if currentlyTrusted {
            self.hasAccessibilityPermission = true
            AppLog.permissions.notice("Accessibility permission already granted")
            refreshPermissions()
            return
        }
        
        // If not trusted and prompt is requested, open System Settings directly
        // Note: AXIsProcessTrustedWithOptions with prompt=true does NOT show a dialog
        // if the app is already in the Accessibility list (even if disabled).
        // The only reliable way is to open System Settings and ask user to enable the toggle.
        if prompt {
            AppLog.permissions.notice("Accessibility not granted, opening System Settings")
            openAccessibilitySettings()
            showAccessibilityInstructionsToast()
        } else {
            self.hasAccessibilityPermission = false
            AppLog.permissions.notice("Accessibility permission denied")
            refreshPermissions()
        }
    }
    
    /// Surface accessibility instructions via the error toast (Step 7).
    /// Replaces the old blocking alert modal (removed in Step 7). The toast shows a
    /// 6s dismissable notification; the user then acts in System Settings. If they
    /// grant access, watchForAccessibilityRestart() will fire restartApp().
    private func showAccessibilityInstructionsToast() {
        ErrorLogger.shared.log(
            message: "Accessibility permission not granted — opened System Settings",
            category: "permissions"
        )
        AppLog.permissions.notice("Showing accessibility instructions toast")
        onToastError?(
            "Accessibility permission required",
            "Find VoiceType in System Settings → Privacy → Accessibility and enable the toggle."
        )
    }
    
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
        AppLog.permissions.notice("Opened Accessibility settings")

        // Watch for permission changes and prompt user to restart when granted
        watchForAccessibilityRestart()
    }

    /// After user enables Accessibility in System Settings, watch for it and prompt to restart.
    /// macOS requires a full app restart for Accessibility permissions to take effect.
    private func watchForAccessibilityRestart() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            let maxAttempts = 30 // 30 seconds max
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                guard let self, !Task.isCancelled else { return }

                // Check without prompting
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
                if AXIsProcessTrustedWithOptions(options) {
                    self.hasAccessibilityPermission = true
                    AppLog.permissions.notice("Accessibility permission detected after grant!")
                    self.showRestartRequiredToast()
                    return
                }
            }
        }
    }

    /// Notify the user via toast that a restart is required.
    /// The toast is persistent (no 6s auto-dismiss) — it stays visible until
    /// restartApp() terminates the process. onHideToast() is called first so the
    /// window closes cleanly before NSApp.terminate fires. P2 finding #3.
    private func showRestartRequiredToast() {
        ErrorLogger.shared.log(
            message: "Accessibility permission granted — restarting automatically",
            category: "permissions"
        )
        AppLog.permissions.notice("Accessibility granted, showing restart toast and restarting")
        // Show a persistent toast; the watcher (not a timer) will dismiss it.
        onShowPersistentToast?(
            "Accessibility permission granted",
            "VoiceType will restart now to activate the permission."
        )
        // Brief delay so the toast renders before the app terminates.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.onHideToast?()
            restartApp()
        }
    }

    /// Restart the app — used when Accessibility permission was granted but the running
    /// process was started before the permission was granted (cached stale state).
    /// Called from the FirstLaunchWindow "Restart App" button — no NSAlert needed.
    func restartAppForAccessibility() {
        ErrorLogger.shared.log(
            message: "Restarting for accessibility permission",
            category: "permissions"
        )
        AppLog.permissions.notice("Restarting app for accessibility permission")
        restartApp()
    }

    // MARK: - Private restart helper

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            NSApp.terminate(nil)
        }
    }
    
    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        
        NSWorkspace.shared.open(url)
        AppLog.permissions.notice("Opened Microphone settings")
        refreshPermissions()
    }
}
