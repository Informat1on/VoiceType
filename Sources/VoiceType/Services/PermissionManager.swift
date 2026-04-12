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
    
    init() {
        checkAllPermissions()
    }
    
    func checkAllPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
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
            
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.hasMicrophonePermission = granted
                }
            }
            
        case .denied, .restricted:
            hasMicrophonePermission = false
            
        @unknown default:
            hasMicrophonePermission = false
        }
    }
    
    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
    }
    
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        
        NSWorkspace.shared.open(url)
    }
    
    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        
        NSWorkspace.shared.open(url)
    }
}
