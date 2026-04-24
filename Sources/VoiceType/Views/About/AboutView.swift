import SwiftUI

struct AboutView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        WindowSurface(
            title: "About VoiceType",
            subtitle: "A local-first macOS voice typing companion built around whisper.cpp, fast text insertion, and a lightweight menu bar workflow.",
            symbol: "info.circle",
            chips: ["On-device transcription", "Whisper.cpp", "Menu bar app"]
        ) {
            SettingsSectionCard(title: "Build", description: "Clean metadata that is safe to publish when you push the repository.") {
                SettingsValueRow("Version") {
                    Text(appVersion)
                }

                SettingsValueRow("Bundle") {
                    Text(Bundle.main.bundleIdentifier ?? "VoiceType")
                        .foregroundStyle(.secondary)
                }

                SettingsValueRow("Platform") {
                    Text("macOS 13+")
                }
            }

            SettingsSectionCard(title: "Current Setup", description: "A quick snapshot of the local configuration currently driving voice input.") {
                SettingsValueRow("Shortcut") {
                    shortcutBadge
                }

                SettingsValueRow("Model") {
                    Text(settings.selectedModel.displayName)
                }

                SettingsValueRow("Language") {
                    Text(languageLabel)
                }

                SettingsValueRow("Insertion") {
                    Text(settings.textInjectionMode.displayName)
                }
            }

            SettingsSectionCard(title: "Permissions", description: "VoiceType only needs the permissions required to listen to your microphone and type back into the focused app.") {
                SettingsValueRow("Microphone") {
                    permissionBadge(permissionManager.hasMicrophonePermission)
                }

                SettingsValueRow("Accessibility") {
                    permissionBadge(permissionManager.hasAccessibilityPermission)
                }
            }

            SettingsSectionCard(title: "Privacy", description: "This app is designed to stay publishable without leaking personal information.") {
                Text("Audio is transcribed locally on your Mac, and the resulting text is only inserted into the active field after you explicitly trigger recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 460, height: 560)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var languageLabel: String {
        settings.language.displayName
    }

    private var shortcutBadge: some View {
        Text("\(modifiersToString(settings.hotkeyModifiers))\(keyCodeToString(settings.hotkeyKey))")
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
    }

    private func permissionBadge(_ isGranted: Bool) -> some View {
        StatusBadge(isGranted ? "Granted" : "Needs attention", tone: isGranted ? .positive : .warning)
    }
}
