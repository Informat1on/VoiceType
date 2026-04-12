import Foundation

// Keep verbose diagnostics available in debug builds without leaking runtime
// metadata into release logs for a microphone-driven app.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
#endif
}
