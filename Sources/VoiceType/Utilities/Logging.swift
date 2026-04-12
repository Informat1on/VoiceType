import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.voicetype.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let models = Logger(subsystem: subsystem, category: "models")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let insertion = Logger(subsystem: subsystem, category: "insertion")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}

// Keep verbose diagnostics available in debug builds without leaking runtime
// metadata into release logs for a microphone-driven app.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
#endif
}
