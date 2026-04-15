import XCTest
@testable import VoiceType

final class KeyboardLayoutKeyResolverTests: XCTestCase {
    func testSpaceUsesHardwareSpaceKey() {
        let resolver = KeyboardLayoutKeyResolver()

        let keystroke = resolver.keystroke(for: " ")

        XCTAssertEqual(keystroke?.keyCode, 0x31)
        XCTAssertEqual(keystroke?.flags, [])
    }

    func testTabAndReturnUseHardwareKeys() {
        let resolver = KeyboardLayoutKeyResolver()

        XCTAssertEqual(resolver.keystroke(for: "\t")?.keyCode, 0x30)
        XCTAssertEqual(resolver.keystroke(for: "\n")?.keyCode, 0x24)
    }

    func testPasteModeStaysPaste() {
        XCTAssertEqual(
            TextInjectionService.effectiveInjectionMode(
                for: .paste,
                frontmostBundleIdentifier: "com.anthropic.claudecode",
                localizedName: "Claude Code"
            ),
            .paste
        )
    }

    func testTypeModeStaysTypeForOtherApps() {
        XCTAssertEqual(
            TextInjectionService.effectiveInjectionMode(
                for: .type,
                frontmostBundleIdentifier: "com.apple.TextEdit",
                localizedName: "TextEdit"
            ),
            .type
        )
    }

    func testTypeModeFallsBackToPasteForClaudeCode() {
        XCTAssertEqual(
            TextInjectionService.effectiveInjectionMode(
                for: .type,
                frontmostBundleIdentifier: "com.anthropic.claudecode",
                localizedName: "Claude Code"
            ),
            .paste
        )
    }

    func testClaudeCodeDetectionMatchesBundleIdentifier() {
        XCTAssertTrue(
            TextInjectionService.looksLikeClaudeCode(
                bundleIdentifier: "com.anthropic.claudecode",
                localizedName: "Something Else"
            )
        )
    }

    func testClaudeCodeDetectionMatchesLocalizedName() {
        XCTAssertTrue(
            TextInjectionService.looksLikeClaudeCode(
                bundleIdentifier: "com.example.app",
                localizedName: "Claude Code"
            )
        )
    }

    func testClaudeCodeDetectionIgnoresOtherApps() {
        XCTAssertFalse(
            TextInjectionService.looksLikeClaudeCode(
                bundleIdentifier: "com.apple.TextEdit",
                localizedName: "TextEdit"
            )
        )
    }
}
