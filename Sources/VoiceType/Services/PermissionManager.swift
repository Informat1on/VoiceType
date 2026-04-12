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
        refreshPermissions()
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
