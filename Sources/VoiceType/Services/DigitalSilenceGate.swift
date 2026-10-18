// DigitalSilenceGate.swift — VoiceType
//
// docs/plans/shadow-vad.md §8, docs/plans/silence-gate.md.

import Foundation

/// docs/plans/shadow-vad.md §8, docs/plans/silence-gate.md.
enum DigitalSilenceGate {
    /// RMS of the whole recording (float samples, [-1, 1]) below which the
    /// recording is treated as digital silence.
    static let rmsThreshold: Double = 0.002

    /// The gate's single API and single decision point — ONE pass over the
    /// array. Both the production path (`AppDelegate.runASR`) and the replay
    /// harness call only this; tests exercise `Decision`.
    struct Decision: Equatable {
        let rms: Double
        let isDigitalSilence: Bool
    }

    /// `rms` = sqrt(Σ Double(x)·Double(x) / Double(count)), no intermediate
    /// arrays or copies. An empty array yields `rms == 0`.
    ///
    /// `isDigitalSilence` ⇔ `samples` is non-empty AND `rms` is finite AND
    /// `rms < rmsThreshold` (strict). An empty array yields `false` — the
    /// empty-recording decision is made further up the stack. A non-finite
    /// `rms` (NaN/Inf samples) also yields `false`: fail-open toward
    /// transcribing when in doubt, preserving prior behavior.
    nonisolated static func evaluate(_ samples: [Float]) -> Decision {
        guard !samples.isEmpty else {
            return Decision(rms: 0, isDigitalSilence: false)
        }

        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()

        let isDigitalSilence = rms.isFinite && rms < rmsThreshold
        return Decision(rms: rms, isDigitalSilence: isDigitalSilence)
    }
}
