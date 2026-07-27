// AppDelegate+EvalHotkey.swift — VoiceType
//
// Carbon plumbing for the eval-collector hotkey (Cmd+Opt+E), split out of
// AppDelegate.swift. The mechanism is self-contained — register, unregister,
// and one event callback — and it shares nothing with the recording pipeline
// beyond calling openEvalEditor(), so it reads better on its own than buried
// between window management and the transcription flow.
//
// Extracted when AppDelegate crossed the 1200-line file_length error threshold
// (SwiftLint). Splitting off a whole mechanism was preferred over raising the
// limit: the cap is doing its job, and this is the piece that least belongs in
// the delegate. Behaviour is unchanged — the code moved verbatim.

import AppKit
import Carbon

extension AppDelegate {

    func registerEvalHotkey() {
        // Key code for 'E' = 14 (Carbon virtual key code)
        // Modifiers: cmdKey (256) | optionKey (2048)
        let keyCode: UInt32 = 14
        let modifiers = UInt32(cmdKey | optionKey)

        var eventSpecs: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        let target = GetApplicationEventTarget()

        let regError = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.evalHotKeySignature, id: Self.evalHotKeyId),
            target,
            0,
            &evalHotKeyRef
        )

        guard regError == noErr else {
            print("[AppDelegate] Failed to register eval hotkey (Cmd+Opt+E), error: \(regError)")
            return
        }

        let handlerError = InstallEventHandler(
            target,
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                return delegate.handleEvalHotkeyEvent(event)
            },
            Int(eventSpecs.count),
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &evalEventHandler
        )

        guard handlerError == noErr else {
            print("[AppDelegate] Failed to install eval event handler, error: \(handlerError)")
            UnregisterEventHotKey(evalHotKeyRef)
            evalHotKeyRef = nil
            return
        }

        print("[AppDelegate] Eval hotkey registered: Cmd+Opt+E")
    }

    func unregisterEvalHotkey() {
        if let handler = evalEventHandler {
            RemoveEventHandler(handler)
            evalEventHandler = nil
        }
        if let hotkey = evalHotKeyRef {
            UnregisterEventHotKey(hotkey)
            evalHotKeyRef = nil
        }
    }

    private func handleEvalHotkeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyId = EventHotKeyID()
        let error = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyId
        )
        guard error == noErr,
              hotKeyId.signature == Self.evalHotKeySignature,
              hotKeyId.id == Self.evalHotKeyId else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async { [weak self] in
            self?.openEvalEditor()
        }
        return noErr
    }
}
