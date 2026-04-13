import Foundation
import Combine
import AVFoundation
import ApplicationServices
import AppKit

@MainActor
final class PermissionManager: ObservableObject {
    
    @Published var hasMicrophonePermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        self.hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
        AppLog.permissions.notice("Accessibility permission updated: \(self.hasAccessibilityPermission, privacy: .public)")
        refreshPermissions()
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
                    self.showRestartRequiredAlert()
                    return
                }
            }
        }
    }

    /// Show alert asking user to restart the app. Accessibility permissions require
    /// a full process restart on macOS — simply closing the window is not enough.
    private func showRestartRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission granted!"
        alert.informativeText = "macOS requires VoiceType to be fully restarted for Accessibility permissions to take effect.\n\nThe app will now quit and relaunch automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.runModal()

        // Relaunch the app
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            NSApp.terminate(nil)
        }
    }

    /// Restart the app — used when Accessibility permission was granted but the running
    /// process was started before the permission was granted (cached stale state).
    func restartAppForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Restart required"
        alert.informativeText = "macOS requires VoiceType to be restarted for Accessibility permissions to take effect.\n\nThe app will quit and relaunch automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

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
