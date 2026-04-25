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
    private var errorToastWindow: ErrorToastWindow?
    private var modelLoadTask: Task<Void, Never>?
    private var pendingModelLoadRequest: ModelLoadRequest?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var firstLaunchWindow: FirstLaunchWindow?
    private var cancellables = Set<AnyCancellable>()

    /// Set to `true` by `injectText` when it shows an `.errorInline` capsule state.
    /// Cleared by `transcribeAndInject`'s else-branch so the capsule is NOT hidden
    /// immediately after `injectText` already presented the inline error.
    /// P2 review finding #1 (flag approach — less intrusive than enum return type).
    private var pendingErrorInlineShown = false

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] === Launching VoiceType ===")
        AppLog.app.notice("Application launching")
        registerEmbeddedFonts()
        NSApp.setActivationPolicy(.accessory)

        voiceTypeWindow = VoiceTypeWindow(audioService: audioCaptureService)
        errorToastWindow = ErrorToastWindow()

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

        // Wire PermissionManager → errorToast so permissions code never calls NSAlert.
        permissionManager.onToastError = { [weak self] title, body in
            self?.showErrorToast(title: title, body: body)
        }
        // Wire persistent-toast callbacks for the restart-required notification.
        // P2 finding #3.
        permissionManager.onShowPersistentToast = { [weak self] title, body in
            guard let self else { return }
            print("[AppDelegate] PERSISTENT TOAST — \(title): \(body)")
            AppLog.app.error("Persistent toast: \(title, privacy: .public)")
            ErrorLogger.shared.log(message: "\(title): \(body)", category: "app")
            // Fire VoiceOver announcement — mirrors showErrorToast path.
            // P2-1: persistent restart toast must announce via the same
            // announcementCopy(for: .errorToast(...)) path as normal toasts.
            // The user just performed a permission grant; restart fires ~600ms
            // later — sufficient for VoiceOver to begin speaking.
            let announcement = self.voiceTypeWindow?.stateModel.announcementCopy(
                for: .errorToast(title: title, body: body)
            ) ?? "\(title). \(body)."
            self.voiceTypeWindow?.stateModel.announcer(announcement)
            self.errorToastWindow?.show(title: title, body: body, persistent: true)
        }
        permissionManager.onHideToast = { [weak self] in
            self?.errorToastWindow?.hide()
        }
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
                ErrorLogger.shared.log(error, category: "models", context: ["model": model.rawValue])
                showErrorToast(
                    title: "Model download failed",
                    body: "Could not download \(model.rawValue). Check your connection and try again in Settings."
                )
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
                // P2-2: log non-critical CoreML failure to file for diagnostics.
                ErrorLogger.shared.log(error, category: "models", context: ["model": model.rawValue, "stage": "coreml"])
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
            ErrorLogger.shared.log(error, category: "models", context: ["model": model.rawValue])
            showErrorToast(
                title: "Model load failed",
                body: "\(model.rawValue) could not be loaded. Try selecting it again in Settings."
            )
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

        // Capture previous app + screen BEFORE showing the capsule so that
        // VoiceType has not yet become frontmost. DESIGN.md § Focus Return.
        FocusCaptureService.shared.capture()

        permissionManager.checkAllPermissions()
        let recordingReadiness = Self.recordingReadiness(
            hasMicrophonePermission: permissionManager.hasMicrophonePermission
        )

        guard recordingReadiness == .ready else {
            AppLog.permissions.error("Blocked recording start because microphone permission is missing")
            permissionManager.requestMicrophonePermission()
            ErrorLogger.shared.log(message: "Recording blocked: microphone permission missing", category: "permissions")
            // User has been directed to System Settings to grant permission. Don't
            // auto-pull focus back to the captured app on errorInline auto-dismiss.
            FocusCaptureService.shared.suppressNextRestore()
            voiceTypeWindow?.show(state: .errorInline(message: "Mic denied · Open Privacy"))
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
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
            ErrorLogger.shared.log(error, category: "app")
            voiceTypeWindow?.show(state: .errorInline(message: "Failed to start recording"))
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
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

        // Pre-hide permission check: if mic permission has been revoked and we
        // captured no audio, we are about to open System Settings. Suppress focus
        // restore BEFORE the initial hide() so that hide() → restore() does not
        // yank focus away from System Settings.
        //
        // Ordering invariant: suppressNextRestore() MUST run before the first
        // voiceTypeWindow?.hide() call on any path that opens System Settings.
        //
        // We check permission here rather than waiting for the empty-samples guard
        // below because we need the suppress flag set before hide() fires restore().
        // The empty-samples guard confirms the actual audio outcome; this early
        // check satisfies the suppress-before-hide ordering requirement.
        permissionManager.checkAllPermissions()
        if appState == .recording, !permissionManager.hasMicrophonePermission {
            FocusCaptureService.shared.suppressNextRestore()
        }

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
                // permissionManager.checkAllPermissions() was already called above (pre-hide).
                if !permissionManager.hasMicrophonePermission {
                    // suppressNextRestore() was already called above, before hide().
                    // Open System Settings so the user can grant microphone permission.
                    permissionManager.requestMicrophonePermission()
                }
                ErrorLogger.shared.log(
                    message: Self.emptyCaptureErrorMessage(
                        hasMicrophonePermission: permissionManager.hasMicrophonePermission
                    ),
                    category: "app"
                )
                let inlineMsg = permissionManager.hasMicrophonePermission
                    ? "No audio captured · Try again"
                    : "Mic denied · Open Privacy"
                voiceTypeWindow?.show(state: .errorInline(message: inlineMsg))
                voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
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
            ErrorLogger.shared.log(error, category: "app")
            voiceTypeWindow?.show(state: .errorInline(message: "Recording stopped with an error"))
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss()
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
            // P2-2: log to file before showing inline error so the most common
            // runtime failure path produces a diagnostic entry in errors.log.
            ErrorLogger.shared.log(error, category: "transcription")
            // Inline capsule error only — no NSAlert. Blocking modal would
            // steal focus and double-notify the user. Codex review P1.
            // Schedule 4s auto-dismiss so the capsule does not hang indefinitely.
            // P2 review finding #2.
            voiceTypeWindow?.show(state: .errorInline(message: "Transcription failed"))
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss(after: 4)
            appState = .idle
            return
        }

        let text = (transcriptionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            print("[AppDelegate] Transcription produced empty string — flashing emptyResult")
            AppLog.transcription.notice("Transcription produced empty text")
            voiceTypeWindow?.show(state: .emptyResult)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.voiceTypeWindow?.hide()
                self?.appState = .idle
            }
            return
        }

        appState = .injecting

        // Capture target app name BEFORE injection — injection may shift focus.
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let charCount = text.count

        // Keep the app busy until the text is fully inserted, so the next hotkey
        // press cannot race with the paste/typing sequence.
        let injectionSucceeded = injectText(text, mode: AppSettings.shared.textInjectionMode)

        if injectionSucceeded {
            // Flash `.inserted` for 400ms (per v5-inserted-state.html), then hide.
            // appState stays non-idle during the flash so a hotkey press mid-flash
            // cannot pass canStartRecording() and start a new recording.
            voiceTypeWindow?.show(state: .inserted(charCount: charCount, targetAppName: targetAppName))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.voiceTypeWindow?.hide()
                self?.appState = .idle
            }
        } else {
            // Only hide the capsule if injectText did NOT already show an inline error.
            // If pendingErrorInlineShown is true, the capsule is displaying errorInline
            // and the 4s scheduleErrorInlineDismiss will dismiss it. P2 finding #1.
            if !pendingErrorInlineShown {
                voiceTypeWindow?.hide()
            }
            pendingErrorInlineShown = false
            appState = .idle
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

            ErrorLogger.shared.log(error, category: "insertion")
            if case TextInjectionService.TextInjectionError.missingAccessibilityPermission = error {
                permissionManager.openAccessibilitySettings()
                // User has been directed to System Settings to grant permission. Don't
                // auto-pull focus back to the captured app on errorInline auto-dismiss.
                FocusCaptureService.shared.suppressNextRestore()
                voiceTypeWindow?.show(state: .errorInline(message: "Accessibility denied · Open"))
            } else {
                voiceTypeWindow?.show(state: .errorInline(message: "Text insertion failed · Retry"))
            }
            voiceTypeWindow?.stateModel.scheduleErrorInlineDismiss(after: 4)
            // Signal to transcribeAndInject that the inline error is already displayed.
            // Prevents the else-branch from hiding the capsule immediately. P2 finding #1.
            pendingErrorInlineShown = true
            return false
        }
    }

    // MARK: - Error Handling

    /// Show an unsolvable error via the dedicated ErrorToastWindow (Step 7).
    /// Also triggers the VoiceOver announcement by setting CapsuleStateModel.state,
    /// which fires the didSet announcer without rendering the toast on the capsule.
    /// The capsule is NOT shown — errorToastWindow is the only visible surface.
    func showErrorToast(title: String, body: String) {
        print("[AppDelegate] TOAST ERROR — \(title): \(body)")
        AppLog.app.error("Error toast: \(title, privacy: .public)")
        ErrorLogger.shared.log(message: "\(title): \(body)", category: "app")
        // Fire VoiceOver announcement via the stateModel announcer (no capsule shown).
        voiceTypeWindow?.stateModel.announcer(
            voiceTypeWindow?.stateModel.announcementCopy(
                for: .errorToast(title: title, body: body)
            ) ?? "\(title). \(body)."
        )
        errorToastWindow?.show(title: title, body: body)
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
