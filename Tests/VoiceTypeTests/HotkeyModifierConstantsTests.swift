import XCTest
@testable import VoiceType

/// Asserts that the global Carbon modifier constants in AppSettings.swift match
/// Apple's canonical HIToolbox/Events.h values exactly.
///
/// These constants are passed directly to RegisterEventHotKey, which operates
/// on raw Carbon modifier bits. Any mismatch causes the wrong physical key to
/// be registered while the UI displays a different symbol.
///
/// Reference (HIToolbox/Events.h):
///   cmdKey     = 0x0100 = 256  (1 << 8)
///   shiftKey   = 0x0200 = 512  (1 << 9)
///   alphaLock  = 0x0400 = 1024 (1 << 10) — not used for hotkeys, omitted
///   optionKey  = 0x0800 = 2048 (1 << 11)
///   controlKey = 0x1000 = 4096 (1 << 12)
final class HotkeyModifierConstantsTests: XCTestCase {

    func testCmdKeyMatchesCarbon() {
        XCTAssertEqual(cmdKey, 256, "cmdKey must equal 0x0100 per HIToolbox/Events.h")
    }

    func testShiftKeyMatchesCarbon() {
        XCTAssertEqual(shiftKey, 512, "shiftKey must equal 0x0200 per HIToolbox/Events.h")
    }

    func testOptionKeyMatchesCarbon() {
        XCTAssertEqual(optionKey, 2048, "optionKey must equal 0x0800 per HIToolbox/Events.h")
    }

    func testControlKeyMatchesCarbon() {
        XCTAssertEqual(controlKey, 4096, "controlKey must equal 0x1000 per HIToolbox/Events.h")
    }

    /// Verify that optionKey and shiftKey are distinct and non-overlapping bits.
    func testModifierBitsAreDistinct() {
        XCTAssertEqual(optionKey & shiftKey, 0, "optionKey and shiftKey must not share bits")
        XCTAssertEqual(optionKey & cmdKey, 0, "optionKey and cmdKey must not share bits")
        XCTAssertEqual(shiftKey & cmdKey, 0, "shiftKey and cmdKey must not share bits")
        XCTAssertEqual(controlKey & optionKey, 0, "controlKey and optionKey must not share bits")
        XCTAssertEqual(controlKey & shiftKey, 0, "controlKey and shiftKey must not share bits")
        XCTAssertEqual(controlKey & cmdKey, 0, "controlKey and cmdKey must not share bits")
    }

    /// Verify the legacy default hotkey modifier (cmdKey | shiftKey = 768) decodes
    /// correctly after the constant fix. Old stored value 768 = Cmd+Shift,
    /// which is what Carbon always fired — UI now labels it ⌘⇧ (correct).
    func testLegacyDefaultModifierDecodesCorrectly() {
        let legacyDefault = cmdKey | shiftKey  // 256 + 512 = 768
        XCTAssertEqual(legacyDefault, 768)

        let label = modifiersToString(legacyDefault)
        XCTAssertTrue(label.contains("⌘"), "legacy default must include ⌘")
        XCTAssertTrue(label.contains("⇧"), "legacy default must include ⇧")
        XCTAssertFalse(label.contains("⌥"), "legacy default must not include ⌥")
        XCTAssertFalse(label.contains("⌃"), "legacy default must not include ⌃")
    }

    /// Verify that optionKey alone produces the ⌥ symbol and nothing else.
    func testOptionModifierDisplaysCorrectSymbol() {
        let label = modifiersToString(optionKey)
        XCTAssertEqual(label, "⌥", "optionKey alone must display ⌥")
    }

    /// Verify that shiftKey alone produces the ⇧ symbol and nothing else.
    func testShiftModifierDisplaysCorrectSymbol() {
        let label = modifiersToString(shiftKey)
        XCTAssertEqual(label, "⇧", "shiftKey alone must display ⇧")
    }

    func testFactoryDefaultFallbackBitsUnchanged() {
        // Pre-constants-fix, the fallback `optionKey | cmdKey` evaluated to 768
        // (Cmd+Shift+V per Carbon). After the fix, the fallback is written as
        // `shiftKey | cmdKey` which evaluates to the SAME 768. This preserves
        // physical hotkey behavior for users on factory defaults.
        let fallbackBits = shiftKey | cmdKey
        // 768 = Cmd+Shift+V physical bits; must not change after constant rename.
        XCTAssertEqual(fallbackBits, 768, "Factory default fallback must stay 768 (Cmd+Shift+V)")
    }

    /// Confirm the UCKeyTranslate shift values (modifiers >> 8) are correct.
    /// UCKeyTranslate Shift bit = 2, Option bit = 8.
    func testUCKeyTranslateShiftBits() {
        XCTAssertEqual(shiftKey >> 8, 2, "shiftKey >> 8 must be 2 for UCKeyTranslate")
        XCTAssertEqual(optionKey >> 8, 8, "optionKey >> 8 must be 8 for UCKeyTranslate")
        XCTAssertEqual((shiftKey | optionKey) >> 8, 10, "(shiftKey|optionKey) >> 8 must be 10 for UCKeyTranslate")
    }

    // MARK: - Legacy Control bit migration

    func testLegacyControlBitMigration() {
        // Ctrl-only: stored 1024, migrated to 4096
        XCTAssertEqual(migrateLegacyControlBit(1024), controlKey,
            "Bare Ctrl must migrate 1024 → 4096")
        // Ctrl+Cmd: stored 1024 | 256 = 1280 → 4096 | 256 = 4352
        XCTAssertEqual(migrateLegacyControlBit(1024 | 256), controlKey | cmdKey,
            "Ctrl+Cmd must preserve Cmd bit")
    }

    func testLegacyMigrationIdempotent() {
        // No legacy 1024 bit: unchanged
        XCTAssertEqual(migrateLegacyControlBit(shiftKey | cmdKey), shiftKey | cmdKey)
        XCTAssertEqual(migrateLegacyControlBit(optionKey | cmdKey), optionKey | cmdKey)
        // Already migrated (4096 present, 1024 absent): unchanged
        XCTAssertEqual(migrateLegacyControlBit(controlKey | cmdKey), controlKey | cmdKey)
        XCTAssertEqual(migrateLegacyControlBit(controlKey | shiftKey | optionKey | cmdKey),
                       controlKey | shiftKey | optionKey | cmdKey)
    }

    func testLegacyCtrlShiftRemapsCompanionBits() {
        // User recorded physical Ctrl+Shift: stored 1024 (old Ctrl) | 2048 (old Shift) = 3072
        // Post-migration: 4096 (new Ctrl) | 512 (new Shift) = 4608
        XCTAssertEqual(migrateLegacyControlBit(3072), 4608,
            "Ctrl+Shift must migrate 3072 → 4608 via companion bit swap")
        XCTAssertEqual(migrateLegacyControlBit(3072), controlKey | shiftKey)
    }

    func testLegacyCtrlOptionRemapsCompanionBits() {
        // User recorded physical Ctrl+Option: stored 1024 (old Ctrl) | 512 (old Option) = 1536
        // Post-migration: 4096 (new Ctrl) | 2048 (new Option) = 6144
        XCTAssertEqual(migrateLegacyControlBit(1536), 6144,
            "Ctrl+Option must migrate 1536 → 6144 via companion bit swap")
        XCTAssertEqual(migrateLegacyControlBit(1536), controlKey | optionKey)
    }

    func testLegacyCtrlShiftOptionRemapsCompanionBits() {
        // User recorded physical Ctrl+Shift+Option: stored 1024 | 2048 | 512 = 3584
        // Post-migration: 4096 | 512 | 2048 = 6656
        XCTAssertEqual(migrateLegacyControlBit(3584), 6656)
        XCTAssertEqual(migrateLegacyControlBit(3584),
                       controlKey | shiftKey | optionKey)
    }

    func testLegacyMigrationPreservesCmdBit() {
        // Ctrl+Cmd+Shift: stored 1024 | 256 | 2048 = 3328 → 4096 | 256 | 512 = 4864
        XCTAssertEqual(migrateLegacyControlBit(3328), 4864)
    }
}
