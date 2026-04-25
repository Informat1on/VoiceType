// ReducedMotionTests.swift
//
// Tests for DESIGN.md § Reduced motion helpers.
// Exercises the two pure functions introduced by Chunk P:
//   - BreathingMod.opacityFromScale(_:) — dot opacity mapper
//   - insertedFlashDurationMs(reduceMotion:) — flash duration picker

import XCTest
@testable import VoiceType

final class ReducedMotionTests: XCTestCase {

    // MARK: - BreathingMod.opacityFromScale

    /// Scale 0.5 (minimum) should map to opacity 0.4 (floor).
    func testOpacityFloorAtMinScale() {
        XCTAssertEqual(opacityFromScale(0.5), 0.4, accuracy: 0.001)
    }

    /// Scale 1.3 (maximum) should map to opacity 1.0 (ceiling).
    func testOpacityCeilingAtMaxScale() {
        XCTAssertEqual(opacityFromScale(1.3), 1.0, accuracy: 0.001)
    }

    /// Scale 0.9 (midpoint of 0.5..1.3) should map to opacity 0.7.
    func testOpacityMidpoint() {
        // normalized = (0.9 - 0.5) / 0.8 = 0.5 → opacity = 0.4 + 0.6*0.5 = 0.7
        XCTAssertEqual(opacityFromScale(0.9), 0.7, accuracy: 0.001)
    }

    /// Sub-floor scale (< 0.5) should clamp to 0.4.
    func testOpacityClampsBelowFloor() {
        XCTAssertEqual(opacityFromScale(0.0), 0.4, accuracy: 0.001)
    }

    /// Above-ceiling scale (> 1.3) should clamp to 1.0.
    func testOpacityClampsAboveCeiling() {
        XCTAssertEqual(opacityFromScale(2.0), 1.0, accuracy: 0.001)
    }

    // MARK: - insertedFlashDurationMs

    /// Without Reduce Motion, flash should be 400ms.
    func testFlashDurationDefaultIs400ms() {
        XCTAssertEqual(insertedFlashDurationMs(reduceMotion: false), 400)
    }

    /// With Reduce Motion, flash should be 200ms.
    func testFlashDurationReducedMotionIs200ms() {
        XCTAssertEqual(insertedFlashDurationMs(reduceMotion: true), 200)
    }

    /// Verify that the reduced value is strictly shorter than the default.
    func testReducedFlashIsShorterThanDefault() {
        let reduced = insertedFlashDurationMs(reduceMotion: true)
        let normal  = insertedFlashDurationMs(reduceMotion: false)
        XCTAssertLessThan(reduced, normal)
    }
}
