// ReinsertService.swift — VoiceType Save & Insert
//
// Restores focus to a FocusSnapshot and pastes corrected text there. When the
// target cannot be trusted (app gone, window not frontmost after restore) the
// text goes to the clipboard instead of a wrong window.
// docs/plans/fix-and-reinsert.md § C2.

import AppKit

enum ReinsertOutcome: Equatable {
    case inserted
    case copied
    case failed(String)
    case busy
}

@MainActor
final class ReinsertService {

    static let shared = ReinsertService()

    typealias Restorer = @MainActor (FocusSnapshot) -> Bool
    typealias Inserter = @MainActor (String) async throws -> Void
    /// true = written to the pasteboard.
    typealias Copier = @MainActor (String) -> Bool
    /// true only when snapshot.app is frontmost (pid match) AND, if snapshot.window != nil,
    /// the app's AX focused window is CFEqual to it. Default reads NSWorkspace + AX.
    typealias FocusVerifier = @MainActor (FocusSnapshot) -> Bool

    private let restorer: Restorer
    private let inserter: Inserter
    private let copier: Copier
    private let verifier: FocusVerifier
    private let activationDelay: Duration

    private(set) var isInFlight = false

    init(
        restorer: @escaping Restorer = { FocusCaptureService.shared.restore($0) },
        inserter: @escaping Inserter = {
            _ = try await TextInjectionService().insertText($0, mode: .paste, pressEnterAfter: false)
        },
        copier: @escaping Copier = {
            let pb = NSPasteboard.general
            pb.clearContents()
            return pb.setString($0, forType: .string)
        },
        verifier: @escaping FocusVerifier = { FocusCaptureService.shared.isFocused($0) },
        activationDelay: Duration = .milliseconds(150)
    ) {
        self.restorer = restorer
        self.inserter = inserter
        self.copier = copier
        self.verifier = verifier
        self.activationDelay = activationDelay
    }

    /// isInFlight → .busy (nothing done). restorer false → copy. restorer true →
    /// sleep(activationDelay) → app terminated or focus not verified → copy;
    /// else inserter; throw → logged (category "insertion") + .failed.
    func reinsert(_ text: String, into snapshot: FocusSnapshot) async -> ReinsertOutcome {
        guard !isInFlight else { return .busy }
        isInFlight = true
        defer { isInFlight = false }

        guard restorer(snapshot) else { return copy(text) }
        try? await Task.sleep(for: activationDelay)
        if snapshot.app.isTerminated || !verifier(snapshot) { return copy(text) }
        do {
            try await inserter(text)
            return .inserted
        } catch {
            ErrorLogger.shared.log(error, category: "insertion")
            return .failed(error.localizedDescription)
        }
    }

    private func copy(_ text: String) -> ReinsertOutcome {
        copier(text) ? .copied : .failed("Clipboard unavailable")
    }
}
