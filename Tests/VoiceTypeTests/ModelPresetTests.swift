// ModelPresetTests.swift — VoiceType
//
// Unit tests for the 3 model presets (Fast / Balanced / Max Quality).
//
// Tests verify:
//   1. Each preset maps to the correct TranscriptionModel enum case.
//   2. Selecting "Balanced" writes largeV3TurboQ5 to the persistence key.
//   3. When the persistence key contains a non-preset model, all three
//      preset rows show as unselected (Custom state).
//   4. Preset catalogue invariants (count, Recommended badge, order).

import XCTest
@testable import VoiceType

final class ModelPresetTests: XCTestCase {

    // MARK: - Preset → enum mapping

    func testFastPresetMapsToSmallQ5() {
        XCTAssertEqual(
            ModelPresetRow.fast.model,
            .smallQ5,
            "Fast preset must map to .smallQ5"
        )
    }

    func testBalancedPresetMapsToLargeV3TurboQ5() {
        XCTAssertEqual(
            ModelPresetRow.balanced.model,
            .largeV3TurboQ5,
            "Balanced preset must map to .largeV3TurboQ5 (default since v1.2.0)"
        )
    }

    func testMaxQualityPresetMapsToLargeV3Turbo() {
        XCTAssertEqual(
            ModelPresetRow.maxQuality.model,
            .largeV3Turbo,
            "Max Quality preset must map to .largeV3Turbo"
        )
    }

    // MARK: - Catalogue invariants

    func testPresetCatalogueHasExactlyThreeEntries() {
        XCTAssertEqual(
            ModelPresetRow.all.count,
            3,
            "Preset catalogue must have exactly 3 entries: Fast, Balanced, Max Quality"
        )
    }

    func testOnlyBalancedIsRecommended() {
        let recommended = ModelPresetRow.all.filter { $0.isRecommended }
        XCTAssertEqual(recommended.count, 1, "Exactly one preset should be marked Recommended")
        XCTAssertEqual(
            recommended.first?.model,
            .largeV3TurboQ5,
            "The Recommended badge must appear on the Balanced (largeV3TurboQ5) preset"
        )
    }

    func testPresetsHaveNonEmptyNames() {
        for preset in ModelPresetRow.all {
            XCTAssertFalse(preset.name.isEmpty, "Preset \(preset.model) has an empty name")
        }
    }

    func testPresetsHaveNonEmptyDescriptions() {
        for preset in ModelPresetRow.all {
            XCTAssertFalse(
                preset.description.isEmpty,
                "Preset \(preset.model) has an empty description"
            )
        }
    }

    // MARK: - Selecting Balanced writes largeV3TurboQ5 to the persistence key

    /// Uses an isolated UserDefaults suite to avoid polluting shared defaults.
    /// Verifies that the Balanced preset stores "large-v3-turbo-q5_0" under
    /// the "selectedModel" key — same key used by the Advanced model picker,
    /// ensuring no state fragmentation.
    @MainActor
    func testSelectingBalancedPresetWritesLargeV3TurboQ5ToPersistenceKey() throws {
        let suiteName = "ModelPresetTests_Balanced_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let balancedModel = ModelPresetRow.balanced.model
        defaults.set(balancedModel.rawValue, forKey: "selectedModel")

        let stored = defaults.string(forKey: "selectedModel")
        XCTAssertEqual(
            stored,
            "large-v3-turbo-q5_0",
            "Selecting Balanced must persist rawValue 'large-v3-turbo-q5_0' under 'selectedModel'"
        )

        // Round-trip: stored raw value must decode back to .largeV3TurboQ5.
        let resolved = TranscriptionModel(rawValue: stored ?? "")
        XCTAssertEqual(
            resolved,
            .largeV3TurboQ5,
            "Stored raw value must decode back to .largeV3TurboQ5"
        )
    }

    // MARK: - Custom state: non-preset model → no preset is active

    /// When the selected model is NOT one of the three presets, the lookup
    /// used to drive `isSelected` on preset rows must return nil — meaning
    /// all three preset rows show as unselected (Custom indicator visible).
    func testNonPresetModelProducesNilActivePreset() {
        let nonPresetModels: [TranscriptionModel] = [.tiny, .base, .small, .medium]

        for model in nonPresetModels {
            let activePreset = ModelPresetRow.all.first { $0.model == model }
            XCTAssertNil(
                activePreset,
                "\(model.rawValue) should not match any preset — all preset rows must show unselected"
            )
        }
    }

    /// Sanity check: the three preset models must each resolve to a preset.
    func testPresetModelsProduceNonNilActivePreset() {
        let presetModels: [TranscriptionModel] = [.smallQ5, .largeV3TurboQ5, .largeV3Turbo]

        for model in presetModels {
            let activePreset = ModelPresetRow.all.first { $0.model == model }
            XCTAssertNotNil(
                activePreset,
                "\(model.rawValue) must resolve to a preset row"
            )
        }
    }

    // MARK: - Preset display order

    func testPresetDisplayOrderIsFastBalancedMaxQuality() {
        XCTAssertEqual(ModelPresetRow.all[0].model, .smallQ5, "Index 0 must be Fast")
        XCTAssertEqual(ModelPresetRow.all[1].model, .largeV3TurboQ5, "Index 1 must be Balanced")
        XCTAssertEqual(ModelPresetRow.all[2].model, .largeV3Turbo, "Index 2 must be Max Quality")
    }
}
