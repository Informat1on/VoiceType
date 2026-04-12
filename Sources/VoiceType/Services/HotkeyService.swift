import Cocoa
import Combine
import Carbon

final class HotkeyService: ObservableObject {
    
    @Published private(set) var isRecording = false
    var isEnabled = true
    
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    
    /// Closure to check if recording can start (delegates to AppDelegate state)
    var canStartRecording: () -> Bool = { true }
    
    private var eventHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var mode: ActivationMode = .singlePress
    private var currentModifiers: UInt32 = 0
    private var currentKeyCode: UInt32 = 0
    private var isKeyDown = false
    
    private enum PendingAction {
        case start
        case stop
        case toggle
    }
    
    private var pendingAction: PendingAction?
    
    private static let hotKeyId: UInt32 = 1
    private static let hotKeySignature: UInt32 = 0x686B3131 // 'hk11'
    
    deinit {
        stopListening()
    }
    
    func startListening(modifiers: Int, keyCode: Int, mode: ActivationMode) {
        stopListening()
        
        self.mode = mode
        self.currentModifiers = UInt32(modifiers)
        self.currentKeyCode = UInt32(keyCode)
        
        var eventSpecs: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        
        let target = GetApplicationEventTarget()
        
        let error = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyId),
            target,
            0,
            &eventHotKey
        )
        
        guard error == noErr else {
            print("HotkeyService: Failed to register hotkey, error: \(error)")
            return
        }
        
        let installError = InstallEventHandler(
            target,
            { _, event, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                return service.handleHotkeyEvent(event!)
            },
            Int(eventSpecs.count),
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        
        guard installError == noErr else {
            print("HotkeyService: Failed to install event handler, error: \(installError)")
            UnregisterEventHotKey(eventHotKey)
            eventHotKey = nil
            return
        }
        
        print("HotkeyService: Listening for hotkey: \(modifiersToString(modifiers))\(keyCodeToString(keyCode)) (mode: \(mode.rawValue), modifiers: \(modifiers), keyCode: \(keyCode))")
    }
    
    func stopListening() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        
        if let eventHotKey {
            UnregisterEventHotKey(eventHotKey)
            self.eventHotKey = nil
        }
        
        isKeyDown = false
        pendingAction = nil
        
        if isRecording {
            stopRecordingInternal()
        }
        
        print("HotkeyService: Stopped listening")
    }
    
    private func handleHotkeyEvent(_ event: EventRef) -> OSStatus {
        guard isEnabled else {
            print("HotkeyService: Hotkey event received but disabled")
            return OSStatus(eventNotHandledErr)
        }
        
        let eventClass = GetEventClass(event)
        let eventKind = GetEventKind(event)
        
        guard eventClass == OSType(kEventClassKeyboard) else {
            print("HotkeyService: Non-keyboard event: class=\(eventClass), kind=\(eventKind)")
            return OSStatus(eventNotHandledErr)
        }
        
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
              hotKeyId.signature == Self.hotKeySignature,
              hotKeyId.id == Self.hotKeyId else {
            print("HotkeyService: Invalid hotkey ID: error=\(error), sig=\(hotKeyId.signature), id=\(hotKeyId.id)")
            return OSStatus(eventNotHandledErr)
        }
        
        print("HotkeyService: Hotkey event: kind=\(eventKind) (pressed=\(kEventHotKeyPressed), released=\(kEventHotKeyReleased))")
        
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            handleKeyDown()
        case UInt32(kEventHotKeyReleased):
            handleKeyUp()
        default:
            print("HotkeyService: Unknown event kind: \(eventKind)")
            return OSStatus(eventNotHandledErr)
        }
        
        return noErr
    }
    
    private func handleKeyDown() {
        guard !isKeyDown else { return }
        isKeyDown = true
        
        switch mode {
        case .singlePress:
            queueAction(.toggle)
        case .hold:
            queueAction(.start)
        }
    }
    
    private func handleKeyUp() {
        guard isKeyDown else { return }
        isKeyDown = false
        
        if mode == .hold {
            queueAction(.stop)
        }
    }
    
    // MARK: - Thread-Safe Action Queueing
    
    private func queueAction(_ action: PendingAction) {
        // Avoid deadlock if already on main thread
        if Thread.isMainThread {
            executeAction(action)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.executeAction(action)
            }
        }
    }
    
    private func executeAction(_ action: PendingAction) {
        // Coalesce rapid actions to prevent race conditions
        if let pending = self.pendingAction {
            switch (pending, action) {
            case (.start, .stop):
                print("HotkeyService: Coalescing start+stop, canceling both")
                self.pendingAction = nil
                return
                
            case (.stop, .start):
                print("HotkeyService: Coalescing stop+start -> toggle")
                self.pendingAction = .toggle
                return
                
            case (.toggle, .toggle):
                print("HotkeyService: Coalescing toggle+toggle, canceling")
                self.pendingAction = nil
                return
                
            case (.start, .start):
                print("HotkeyService: Duplicate start, ignoring")
                return
                
            case (.stop, .stop):
                print("HotkeyService: Duplicate stop, ignoring")
                return
                
            case (.start, .toggle):
                // start followed by toggle = start then stop
                print("HotkeyService: start+toggle -> execute start now, queue stop")
                self.pendingAction = .stop
                startRecordingInternal()
                return

            case (.stop, .toggle):
                // stop followed by toggle = stop then start
                print("HotkeyService: stop+toggle -> execute stop now, queue start")
                self.pendingAction = .start
                stopRecordingInternal()
                return

            case (.toggle, .start):
                // toggle followed by start = execute toggle first, then start is redundant
                print("HotkeyService: toggle+start -> execute toggle, start redundant")
                toggleRecordingInternal()
                self.pendingAction = nil
                return

            case (.toggle, .stop):
                // toggle followed by stop = execute toggle first, then stop
                print("HotkeyService: toggle+stop -> execute toggle then stop")
                toggleRecordingInternal()
                stopRecordingInternal()
                return
            }
        }
        
        self.pendingAction = action
        processPendingAction()
    }
    
    private func processPendingAction() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        guard let action = pendingAction else { return }
        pendingAction = nil
        
        print("HotkeyService: Processing action: \(action), isRecording=\(isRecording)")
        
        switch action {
        case .start:
            startRecordingInternal()
        case .stop:
            stopRecordingInternal()
        case .toggle:
            toggleRecordingInternal()
        }
    }
    
    // MARK: - Internal Recording Control (Main Thread Only)
    
    private func startRecordingInternal() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        guard !isRecording else {
            print("HotkeyService: Already recording, ignoring start")
            return
        }
        
        guard canStartRecording() else {
            print("HotkeyService: AppDelegate not ready (transcribing/recording), ignoring start")
            return
        }
        
        isRecording = true
        onRecordingStarted?()
        print("HotkeyService: Recording started (callback executed)")
    }
    
    private func stopRecordingInternal() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        guard isRecording else {
            print("HotkeyService: Not recording, ignoring stop")
            return
        }
        
        isRecording = false
        onRecordingStopped?()
        print("HotkeyService: Recording stopped (callback executed)")
    }
    
    private func toggleRecordingInternal() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        if isRecording {
            isRecording = false
            onRecordingStopped?()
            print("HotkeyService: Recording stopped (toggle)")
        } else {
            guard canStartRecording() else {
                print("HotkeyService: AppDelegate not ready (transcribing/recording), ignoring toggle start")
                return
            }
            isRecording = true
            onRecordingStarted?()
            print("HotkeyService: Recording started (toggle)")
        }
    }
}
