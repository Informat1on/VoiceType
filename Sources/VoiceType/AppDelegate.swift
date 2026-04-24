import SwiftUI
import Combine
import CoreText

enum AppState: String {
    case idle
    case recording
    case transcribing
    case injecting
}

enum RecordingReadiness: Equatable {
    case ready
    case missingMicrophonePermission
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private struct ModelLoadRequest {
        let model: TranscriptionModel
        let downloadCoreMLIfNeeded: Bool
    }

    // MARK: - Services

    let hotkeyService = HotkeyService()
    let audioCaptureService = AudioCaptureService()
    let transcriptionService = TranscriptionService()
    let textInjectionService = TextInjectionService()
    let permissionManager = PermissionManager()
    let modelManager = ModelManager.shared

    // MARK: - State

    @Published var appState: AppState = .idle {
        didSet {
            print("[AppDelegate] State: \(oldValue.rawValue) → \(appState.rawValue)")
        }
    }

    /// Timestamp anchored at the moment recording started. Used by MenuBarView
    /// to compute elapsed time for the live recording timer. Cleared on any
    /// transition out of .recording.
    @Published var recordingStartedAt: Date?

    var isSettingsOpen = false {
        didSet {
            hotkeyService.isEnabled = !isSettingsOpen
            print("[AppDelegate] Settings open: \(isSettingsOpen), hotkey enabled: \(hotkeyService.isEnabled)")
        }
    }

    // MARK: - Windows

    private var voiceTypeWindow: VoiceTypeWindow?
    private var modelLoadTask: Task<Void, Never>?
    private var pendingModelLoadRequest: ModelLoadRequest?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var firstLaunchWindow: FirstLaunchWindow?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] === Launching VoiceType ===")
        AppLog.app.notice("Application launching")
        registerEmbeddedFonts()
        NSApp.setActivationPolicy(.accessory)

        voiceTypeWindow = VoiceTypeWindow(audioService: audioCaptureService)

        // Subscribe to .capsuleErrorInlineExpired so the 4s auto-dismiss
        // emitted by CapsuleStateModel actually hides the window.
        // Codex review P2-3.
        NotificationCenter.default.addObserver(
            forName: .capsuleErrorInlineExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if case .errorInline = self?.voiceTypeWindow?.stateModel.state {
                self?.voiceTypeWindow?.hide()
            }
        }

        setupServices()
        setupHotkeyCallbacks()
        setupBindings()
        preloadModelIfNeeded()

        // Show first-launch checklist on first run. Placed after preloadModelIfNeeded()
        // so ModelManager state is queryable when the window opens.
        // DESIGN.md § Implementation Plan Step 4 / Decisions Log D8.
        if !OnboardingState.hasCompleted {
            openFirstLaunchWindow()
        }

        print("[AppDelegate] === Ready. Hotkey: \(modifiersToString(AppSettings.shared.hotkeyModifiers))\(keyCodeToString(AppSettings.shared.hotkeyKey)) ===")
        AppLog.app.notice("Application ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService.stopListening()
        if appState == .recording {
            _ = try? audioCaptureService.stopRecording()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionManager.checkAllPermissions()
    }

    // MARK: - Settings Window

    func openSettings() {
        print("[AppDelegate] openSettings() called")
        permissionManager.checkAllPermissions()

        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "VoiceType Settings",
                size: NSSize(width: 620, height: 520),
                content: SettingsView(permissionManager: permissionManager)
            )
            settingsWindow?.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        isSettingsOpen = true
        print("[AppDelegate] Settings window opened")
    }

    func closeSettings() {
        settingsWindow?.close()
        isSettingsOpen = false
    }

    func openAbout() {
        print("[AppDelegate] openAbout() called")
        permissionManager.checkAllPermissions()

        if aboutWindow == nil {
            aboutWindow = makeWindow(
                title: "About VoiceType",
                size: NSSize(width: 460, height: 560),
                content: AboutView(permissionManager: permissionManager)
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.deminiaturize(nil)
        aboutWindow?.makeKeyAndOrderFront(nil)
        aboutWindow?.orderFrontRegardless()
    }

    func openFirstLaunchWindow() {
        print("[AppDelegate] openFirstLaunchWindow() called")
        if firstLaunchWindow == nil {
            firstLaunchWindow = FirstLaunchWindow(permissionManager: permissionManager)
            firstLaunchWindow?.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        firstLaunchWindow?.deminiaturize(nil)
        firstLaunchWindow?.makeKeyAndOrderFront(nil)
        firstLaunchWindow?.orderFrontRegardless()
    }

    // MARK: - Font Registration

    /// Register Geist and Geist Mono TTFs bundled in Resources/Fonts/ so that
    /// `Font.custom("Geist", ...)` and `Font.custom("Geist Mono", ...)` in
    /// Tokens.swift resolve to the actual typeface instead of falling back to
    /// San Francisco. Must be called BEFORE any SwiftUI view renders.
    /// DESIGN.md § Typography. Tier A Step 14 (accelerated to Step 6).
    private func registerEmbeddedFonts() {
        let fontNames = [
            "Geist-Regular",
            "Geist-Medium",
            "Geist-SemiBold",
            "GeistMono-Regular",
            "GeistMono-Medium"
        ]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("[AppDelegate] Font not found in bundle: \(name).ttf")
                AppLog.app.error("Embedded font missing: \(name, privacy: .public).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if registered {
                print("[AppDelegate] Font registered: \(name)")
            } else if let err = error?.takeRetainedValue() {
                // kCTFontManagerErrorAlreadyRegistered (code 105) is benign — hot-reload.
                let code = CFErrorGetCode(err)
                if code == 105 {
                    print("[AppDelegate] Font already registered (benign): \(name)")
                } else {
                    print("[AppDelegate] Font registration failed: \(name) — \(err)")
                    AppLog.app.error("Font registration failed: \(name, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Setup

    private func setupServices() {
        permissionManager.refreshPermissions()
        // requestInitialPermissionsIfNeeded() removed — FirstLaunchWindow is the
        // sole onboarding surface. See DESIGN.md Decisions Log D8 / Step 4.
    }

    private func setupHotkeyCallbacks() {
        hotkeyService.canStartRecording = { [weak self] in
            guard let self else { return false }
            return self.appState == .idle
        }
        
        hotkeyService.onRecordingStarted = { [weak self] in
            self?.handleRecordingStarted()
        }

        hotkeyService.onRecordingStopped = { [weak self] in
            self?.handleRecordingStopped()
        }

        registerHotkey()
    }

    private func setupBindings() {
        // Use CombineLatest3 for flat tuple (modifiers, keyCode, mode)
        // This avoids nested tuple comparison issues
        Publishers.CombineLatest3(
            AppSettings.shared.$hotkeyModifiers,
            AppSettings.shared.$hotkeyKey,
            AppSettings.shared.$activationMode
        )
        .dropFirst()
        .removeDuplicates { $0 == $1 }
        .sink { [weak self] modifiers, keyCode, mode in
            AppLog.hotkey.notice("Hotkey settings changed: mode=\(mode.rawValue, privacy: .public)")
            self?.registerHotkey(modifiers: modifiers, keyCode: keyCode, mode: mode)
        }
        .store(in: &cancellables)
        
        AppSettings.shared.$selectedModel
            .dropFirst()
            .sink { [weak self] newModel in
                print("[AppDelegate] Model changed to: \(newModel.rawValue)")
                self?.scheduleModelLoad(newModel, downloadCoreMLIfNeeded: false)
            }
            .store(in: &cancellables)
    }

    private func registerHotkey(modifiers: Int, keyCode: Int, mode: ActivationMode) {
        AppLog.hotkey.notice("Registering hotkey: \(modifiersToString(modifiers), privacy: .public)\(keyCodeToString(keyCode), privacy: .public) mode=\(mode.rawValue, privacy: .public)")
        hotkeyService.startListening(
            modifiers: modifiers,
            keyCode: keyCode,
            mode: mode
        )
    }
    
    private func registerHotkey() {
        // Fallback for initial registration - read from current settings
        registerHotkey(
            modifiers: AppSettings.shared.hotkeyModifiers,
            keyCode: AppSettings.shared.hotkeyKey,
            mode: AppSettings.shared.activationMode
        )
    }
    
    private func scheduleModelLoad(_ model: TranscriptionModel, downloadCoreMLIfNeeded: Bool) {
        pendingModelLoadRequest = ModelLoadRequest(
            model: model,
            downloadCoreMLIfNeeded: downloadCoreMLIfNeeded
        )
        startModelLoadTaskIfNeeded()
    }

    private func startModelLoadTaskIfNeeded() {
        guard modelLoadTask == nil else {
            return
        }

        modelLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.processPendingModelLoads()
        }
    }

    private func processPendingModelLoads() async {
        defer {
            modelLoadTask = nil

            // A new selection may arrive while the current task is finishing.
            if pendingModelLoadRequest != nil {
                startModelLoadTaskIfNeeded()
            }
        }

        while let request = pendingModelLoadRequest {
            pendingModelLoadRequest = nil
            await loadModel(for: request)
        }
    }

    private func hasNewerModelLoadRequest(than request: ModelLoadRequest) -> Bool {
        guard let pendingModelLoadRequest else {
            return false
        }

        return pendingModelLoadRequest.model != request.model
    }

    private func loadModel(for request: ModelLoadRequest) async {
        let model = request.model

        let language = AppSettings.shared.language
        print("[AppDelegate] Reloading model: \(model.rawValue) with language: \(language.rawValue)")
        AppLog.models.notice("Reloading model \(model.rawValue, privacy: .public)")

        if !modelManager.isModelDownloaded(model: model) {
            print("[AppDelegate] Model not downloaded, downloading...")
            AppLog.models.notice("Downloading model \(model.rawValue, privacy: .public)")
            do {
                try await modelManager.downloadModel(model: model)
                print("[AppDelegate] Model downloaded successfully")
                AppLog.models.notice("Model download finished for \(model.rawValue, privacy: .public)")
            } catch {
                print("[AppDelegate] Download failed: \(error)")
                AppLog.models.error("Model download failed for \(model.rawValue, privacy: .public)")
                showError("Failed to download model: \(error.localizedDescription)")
                return
            }
        } else if request.downloadCoreMLIfNeeded && model.hasCoreMLSupport && !modelManager.isCoreMLModelDownloaded(model: model) {
            print("[AppDelegate] CoreML not downloaded, downloading for GPU acceleration...")
            AppLog.models.notice("Downloading CoreML assets for \(model.rawValue, privacy: .public)")
            do {
                try await modelManager.downloadModel(model: model)
                print("[AppDelegate] CoreML downloaded successfully")
                AppLog.models.notice("CoreML assets ready for \(model.rawValue, privacy: .public)")
            } catch {
                print("[AppDelegate] CoreML download failed (non-critical): \(error)")
                AppLog.models.error("CoreML download failed for \(model.rawValue, privacy: .public)")
            }
        }

        if hasNewerModelLoadRequest(than: request) {
            print("[AppDelegate] Skipping stale model load for \(model.rawValue)")
            AppLog.models.notice("Skipping stale model load for \(model.rawValue, privacy: .public)")
            return
        }

        let modelURL = modelManager.modelURL(for: model)
        transcriptionService.unloadModel()

        do {
            try await transcriptionService.loadModel(at: modelURL, language: language, model: model)
            print("[AppDelegate] Model reloaded successfully: \(model.rawValue)")
            AppLog.models.notice("Model reloaded: \(model.rawValue, privacy: .public)")
        } catch {
            print("[AppDelegate] Failed to reload model: \(error)")
            AppLog.models.error("Model reload failed for \(model.rawValue, privacy: .public)")
            showError("Failed to load model: \(error.localizedDescription)")
        }
    }

    private func applyInitialPrompt() {
        let userVocabulary = AppSettings.shared.customVocabulary
        transcriptionService.setInitialPrompt(userVocabulary.isEmpty ? nil : userVocabulary)
    }

    private func preloadModelIfNeeded() {
        let model = AppSettings.shared.selectedModel
        let language = AppSettings.shared.language
        print("[AppDelegate] Preload model: \(model.rawValue), language: \(language.rawValue)")
        print("[AppDelegate] Main model downloaded: \(modelManager.isModelDownloaded(model: model))")
        print("[AppDelegate] CoreML support: \(model.hasCoreMLSupport), downloaded: \(modelManager.isCoreMLModelDownloaded(model: model))")
        applyInitialPrompt()
        scheduleModelLoad(model, downloadCoreMLIfNeeded: true)
    }

    // MARK: - Recording Lifecycle

    nonisolated static func recordingReadiness(hasMicrophonePermission: Bool) -> RecordingReadiness {
        hasMicrophonePermission ? .ready : .missingMicrophonePermission
    }

    nonisolated static func microphonePermissionErrorMessage() -> String {
        "Microphone permission is required before recording can start. Open System Settings -> Privacy & Security -> Microphone, enable VoiceType, then try again."
    }

    nonisolated static func emptyCaptureErrorMessage(hasMicrophonePermission: Bool) -> String {
        if hasMicrophonePermission {
            return "VoiceType did not capture any audio. Check the selected input device in macOS and try holding the hotkey a bit longer."
        }

        return microphonePermissionErrorMessage()
    }

    private func handleRecordingStarted() {
        print("[AppDelegate] handleRecordingStarted, currentState: \(appState.rawValue)")
        
        guard appState == .idle else {
            print("[AppDelegate] Ignoring start, not idle")
            return
        }

        permissionManager.checkAllPermissions()
        let recordingReadiness = Self.recordingReadiness(
            hasMicrophonePermission: permissionManager.hasMicrophonePermission
        )

        guard recordingReadiness == .ready else {
            AppLog.permissions.error("Blocked recording start because microphone permission is missing")
            permissionManager.requestMicrophonePermission()
            showError(Self.microphonePermissionErrorMessage())
            appState = .idle
            return
        }

        do {
            try audioCaptureService.startRecording()
            appState = .recording
            recordingStartedAt = Date()
            voiceTypeWindow?.show(state: CapsuleState.recording)
            print("[AppDelegate] Recording started")
            AppLog.app.notice("Recording started")
        } catch {
            print("[AppDelegate] Failed to start recording: \(error)")
            AppLog.app.error("Recording failed to start")
            showError("Failed to start recording: \(error.localizedDescription)")
            appState = .idle
        }
    }

    /// Entry point for the menubar "Start recording" button.
    /// Delegates to the same hotkey-triggered path so state transitions are identical.
    /// After a successful start we sync `HotkeyService.isRecording` so a subsequent
    /// hotkey press (toggle/stop) correctly terminates a menu-initiated recording.
    func startRecordingFromMenu() {
        print("[AppDelegate] startRecordingFromMenu() called")
        handleRecordingStarted()
        if appState == .recording {
            hotkeyService.syncIsRecording(true)
        }
    }

    /// Entry point for the menubar "Stop recording" button.
    /// Symmetric to `startRecordingFromMenu()`: delegates to the same stop path
    /// as the hotkey so state transitions (recording → transcribing) are identical.
    func stopRecordingFromMenu() {
        print("[AppDelegate] stopRecordingFromMenu() called")
        handleRecordingStopped()
    }

    private func handleRecordingStopped() {
        print("[AppDelegate] handleRecordingStopped, currentState: \(appState.rawValue)")
        recordingStartedAt = nil
        voiceTypeWindow?.hide()
        // Sync HotkeyService.isRecording defensively — covers paths that stop via
        // menu / forceReset / error, not just hotkey-triggered stop.
        hotkeyService.syncIsRecording(false)

        guard appState == .recording else {
            print("[AppDelegate] Ignoring stop, not recording (state: \(appState.rawValue))")
            // Defensive: if we're not recording but got a stop, reset audio service just in case
            _ = try? audioCaptureService.stopRecording()
            appState = .idle
            return
        }

        do {
            let samples = try audioCaptureService.stopRecording()
            print("[AppDelegate] Got \(samples.count) audio samples")
            guard !samples.isEmpty else {
                print("[AppDelegate] No audio samples")
                AppLog.app.notice("Recording stopped with no audio")
                permissionManager.checkAllPermissions()
                if !permissionManager.hasMicrophonePermission {
                    permissionManager.requestMicrophonePermission()
                }
                showError(Self.emptyCaptureErrorMessage(
                    hasMicrophonePermission: permissionManager.hasMicrophonePermission
                ))
                appState = .idle
                return
            }

            appState = .transcribing
            voiceTypeWindow?.show(state: CapsuleState.transcribing)
            AppLog.transcription.notice("Transcription started")

            print("[AppDelegate] About to create transcription Task")
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                print("[AppDelegate] Transcription Task started, calling transcribeAndInject")
                await self.transcribeAndInject(samples: samples)
                print("[AppDelegate] Transcription Task completed")
            }
            print("[AppDelegate] Transcription Task created")
        } catch {
            print("[AppDelegate] Failed to stop recording: \(error)")
            AppLog.app.error("Recording failed to stop cleanly")
            showError("Failed to stop recording: \(error.localizedDescription)")
            appState = .idle
        }
    }

    /// Force-reset state to idle. Called when hotkey service detects a press but AppDelegate is out of sync.
    func forceResetToIdle() {
        print("[AppDelegate] forceResetToIdle called, was: \(appState.rawValue)")
        voiceTypeWindow?.hide()
        if appState == .recording {
            _ = try? audioCaptureService.stopRecording()
        }
        recordingStartedAt = nil
        appState = .idle
        print("[AppDelegate] State forced to idle")
    }

    // MARK: - Transcription Pipeline

    private func transcribeAndInject(samples: [Float]) async {
        print("[AppDelegate] transcribeAndInject: \(samples.count) samples")

        var transcriptionText: String?

        do {
            try await ensureModelLoaded()
            print("[AppDelegate] Model ready, starting transcription")

            let text = try await transcriptionService.transcribe(
                audio: samples,
                language: AppSettings.shared.language
            )

            transcriptionText = text
            print("[AppDelegate] Transcription finished successfully")
            AppLog.transcription.notice("Transcription completed")
        } catch {
            print("[AppDelegate] Transcription error: \(error)")
            AppLog.transcription.error("Transcription failed")
            // Inline capsule error only — no NSAlert. Blocking modal would
            // steal focus and double-notify the user. Codex review P1.
            // The 4s auto-dismiss is wired via .capsuleErrorInlineExpired
            // subscriber in applicationDidFinishLaunching.
            voiceTypeWindow?.show(state: .errorInline(message: "Transcription failed"))
            appState = .idle
            return
        }

        let text = (transcriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            print("[AppDelegate] Transcription produced empty string — nothing to inject")
            AppLog.transcription.notice("Transcription produced empty text")
            voiceTypeWindow?.hide()
            appState = .idle
            return
        }

        appState = .injecting

        // Capture target app name BEFORE injection — injection may shift focus.
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let charCount = text.count

        // Keep the app busy until the text is fully inserted, so the next hotkey
        // press cannot race with the paste/typing sequence.
        let injectionSucceeded = injectText(text, mode: AppSettings.shared.textInjectionMode)
        appState = .idle

        if injectionSucceeded {
            // Flash `.inserted` for ~500ms, then hide.
            voiceTypeWindow?.show(state: .inserted(charCount: charCount, targetAppName: targetAppName))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.voiceTypeWindow?.hide()
            }
        } else {
            voiceTypeWindow?.hide()
        }
    }

    private func ensureModelLoaded() async throws {
        while let modelLoadTask {
            await modelLoadTask.value
        }

        guard !transcriptionService.isModelLoaded else {
            print("[AppDelegate] Model already loaded")
            return
        }

        let model = AppSettings.shared.selectedModel
        let language = AppSettings.shared.language
        guard modelManager.isModelDownloaded(model: model) else {
            print("[AppDelegate] Model not downloaded: \(model.rawValue)")
            throw TranscriptionError.modelNotLoaded
        }

        let modelURL = modelManager.modelURL(for: model)
        print("[AppDelegate] Loading model on-demand: \(modelURL.lastPathComponent) with language: \(language.rawValue)")
        try await transcriptionService.loadModel(at: modelURL, language: language, model: model)
    }

    /// Returns `true` on successful injection, `false` on failure. Callers use
    /// the result to decide whether to flash the `.inserted` capsule or route
    /// through the error path.
    @discardableResult
    private func injectText(_ text: String, mode: TextInjectionMode) -> Bool {
        permissionManager.checkAllPermissions()

        print("[AppDelegate] Injecting text (mode: \(mode.rawValue), characters: \(text.count))")
        do {
            try textInjectionService.injectText(
                text,
                mode: mode,
                pressEnterAfter: AppSettings.shared.autoEnterAfterInsert
            )
            print("[AppDelegate] Text injected successfully")
            AppLog.insertion.notice("Text insertion completed")
            return true
        } catch {
            print("[AppDelegate] Text injection failed: \(error)")
            AppLog.insertion.error("Text insertion failed")

            if case TextInjectionService.TextInjectionError.missingAccessibilityPermission = error {
                permissionManager.openAccessibilitySettings()
            }

            showError("Failed to insert text: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Error Handling

    private func showError(_ message: String) {
        print("[AppDelegate] ERROR: \(message)")
        AppLog.app.error("User-facing error presented")
        let alert = NSAlert()
        alert.messageText = "VoiceType Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        return window
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Only flip isSettingsOpen when the settings window itself closes.
        // FirstLaunchWindow shares this delegate but must not re-enable the
        // hotkey while Settings is still visible. Review P1-F1.
        if (notification.object as? NSWindow) === settingsWindow {
            isSettingsOpen = false
        }
    }
}
