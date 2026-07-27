import SwiftUI
import Combine
import CoreText
import Carbon

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
    /// Extracted seam for history bookkeeping (task 1, P1 fix) — see
    /// HistoryRecorder.swift for why AppDelegate delegates this instead of
    /// calling HistoryStore directly.
    let historyRecorder = HistoryRecorder(store: .shared)

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
    /// Guards applicationShouldTerminate against re-entry while the teardown runs.
    private var isShuttingDown = false
    private var pendingModelLoadRequest: ModelLoadRequest?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var firstLaunchWindow: FirstLaunchWindow?
    /// Keyed by entry UUID so multiple eval editors can coexist without losing ownership.
    /// VT-REV-001: replaced single `evalEditorWindow` optional with a dictionary.
    private var evalEditorWindows: [UUID: EvalEditorWindow] = [:]
    /// Block-based NotificationCenter observers tied to eval editor windows.
    /// Stored so we can `removeObserver` when the window closes — otherwise each
    /// opened editor leaks a registration until process exit (Codex re-review).
    private var evalEditorObservers: [UUID: NSObjectProtocol] = [:]
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Eval hotkey (Cmd+Opt+E, separate from the recording hotkey)
    // Internal rather than private: the Carbon plumbing lives in
    // AppDelegate+EvalHotkey.swift, and `private` would not reach across files.
    var evalHotKeyRef: EventHotKeyRef?
    var evalEventHandler: EventHandlerRef?
    /// Static id distinct from HotkeyService.hotKeySignature ('hk11' = 0x686B3131)
    static let evalHotKeySignature: UInt32 = 0x65766C31 // 'evl1'
    static let evalHotKeyId: UInt32 = 42

    /// Set to `true` by `injectText` when it shows an `.errorInline` capsule state.
    /// Cleared by `transcribeAndInject`'s else-branch so the capsule is NOT hidden
    /// immediately after `injectText` already presented the inline error.
    /// P2 review finding #1 (flag approach — less intrusive than enum return type).
    private var pendingErrorInlineShown = false

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] === Launching VoiceType ===")
        AppLog.app.notice("Application launching")
        configureGGMLResourcePath()
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

        // One-shot sweep for scratch directories a hard crash could have left
        // behind (CoreML unzip staging, Metal-only shadow-symlink staging —
        // see ModelManager.cleanUpOrphanedScratchDirectories). Every normal
        // code path already cleans up after itself; this only matters after
        // an abnormal exit, so once per launch — before anything else touches
        // the models directory — is enough.
        modelManager.cleanUpOrphanedScratchDirectories()

        preloadModelIfNeeded()
        registerEvalHotkey()

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
        unregisterEvalHotkey()
        if appState == .recording {
            _ = try? audioCaptureService.stopRecording()
        }
    }

    /// Hold up termination until the whisper context is released.
    ///
    /// applicationWillTerminate is synchronous and cannot await the drain, so the
    /// teardown lives here: reply .terminateLater, release the context (waiting out
    /// any in-flight transcription), then let AppKit finish quitting.  Without this
    /// the context survives into atexit and ggml aborts on
    /// GGML_ASSERT([rsets->data count] == 0) — see TranscriptionService.shutdown().
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second quit request must not slip past the drain still in flight —
        // keep waiting; the running teardown owns the reply.
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true

        Task { @MainActor in
            // Let a model load finish before releasing: bumping the generation only
            // stops the result from being committed, while Whisper(fromFileURL:) keeps
            // building a native context on its background queue. Awaiting the task
            // means that context is created and then dropped by the generation guard.
            if let task = modelLoadTask {
                task.cancel()
                _ = await task.value
                modelLoadTask = nil
            }

            let released = await transcriptionService.shutdown()
            guard released else {
                // A transcription outlived the drain, so the context is still holding
                // Metal buffers. Returning through a normal exit would run ggml's atexit
                // teardown and abort; _exit skips it. We are quitting anyway — the OS
                // reclaims everything.
                AppLog.app.error("Quitting via _exit: whisper context could not be released in time")
                ErrorLogger.shared.log(message: "Forced exit: transcription still running at quit", category: "app")
                _exit(0)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
                content: SettingsView(
                    permissionManager: permissionManager,
                    transcriptionService: transcriptionService
                )
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

    // MARK: - Eval Editor Window

    /// Open an eval editor for a specific history entry.
    /// If a window for this entry is already open, brings it to front instead of creating a duplicate.
    /// VT-REV-001: strong ownership via dictionary; each window cleans itself up on close.
    func openEvalEditorForEntry(_ entryID: UUID) {
        print("[AppDelegate] openEvalEditorForEntry(\(entryID)) called")
        if let existing = evalEditorWindows[entryID] {
            existing.orderFrontRegardless()
            return
        }
        let win = EvalEditorWindow.open(entryID: entryID)
        evalEditorWindows[entryID] = win
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.evalEditorWindows.removeValue(forKey: entryID)
                if let observer = self.evalEditorObservers.removeValue(forKey: entryID) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        evalEditorObservers[entryID] = token
    }

    /// Open the eval editor for the last transcription (Cmd+Opt+E hotkey path).
    /// Shows a brief inline error if no transcription exists yet.
    func openEvalEditor() {
        print("[AppDelegate] openEvalEditor() called")
        guard let last = HistoryStore.shared.latestEntry() else {
            showErrorToast(title: "No transcription yet", body: "Make a transcription first, then press Cmd+Opt+E to edit it.")
            return
        }
        openEvalEditorForEntry(last.id)
    }

    // MARK: - Font Registration

    /// Register Geist and Geist Mono TTFs bundled in Resources/Fonts/ so that
    /// `Font.custom("Geist", ...)` and `Font.custom("Geist Mono", ...)` in
    /// Tokens.swift resolve to the actual typeface instead of falling back to
    /// San Francisco. Must be called BEFORE any SwiftUI view renders.
    /// DESIGN.md § Typography. Tier A Step 14 (accelerated to Step 6).
    /// Point ggml at the Metal shader we ship in Contents/Resources, and pin the
    /// tensor-API flag so the runtime never disagrees with what `default.metallib`
    /// actually contains.
    ///
    /// build-app.sh now precompiles `Contents/MacOS/default.metallib` ahead of time
    /// (upstream recipe, no feature macros — see its "Metal shader library
    /// precompilation" comment). That library is built WITHOUT
    /// `GGML_METAL_HAS_TENSOR`, i.e. every kernel that has a tensor-API/simdgroup
    /// fork (7 of them in ggml-metal.metal) is compiled as the simdgroup version.
    /// The runtime, left to itself, still picks dispatch geometry from a live
    /// hardware probe (`has_tensor = supportsFamily:MTLGPUFamilyMetal4_GGML`,
    /// ggml-metal-device.m:708) — so on M5-family hardware it would probe "tensor
    /// available" and dispatch tensor-shaped work against simdgroup kernels.
    /// `GGML_METAL_TENSOR_DISABLE` is ggml's own escape hatch for exactly this
    /// (ggml-metal-device.m:709-710): it forces `has_tensor = false` before any
    /// dispatch decision is made, keeping the library and the runtime in
    /// agreement on every chip. This must be set before ggml ever touches Metal —
    /// hence first thing in this function, which itself runs first in
    /// `applicationDidFinishLaunching`.
    ///
    /// Side effect, and the reason this doubles as a diagnostics fix rather than
    /// just a crash fix: `AcceleratorCapabilityProvider`'s probe reads the same
    /// `has_tensor` flag, so with it forced off the probe honestly reports
    /// `.metal` instead of `.metalWithTensor` on M5 — it does not have to be told
    /// separately. Cost: the Metal encoder loses the tensor-API speedup on M5
    /// (`.auto` is unaffected — it already prefers the Neural Engine over Metal on
    /// every tier; only a manual Metal-only choice or the Fast preset pays this).
    ///
    /// ggml then compiles ggml-metal.metal at runtime only when no precompiled
    /// library is found (older/unbuilt bundle) — resolution order: default.metallib
    /// next to the binary → $GGML_METAL_PATH_RESOURCES/ggml-metal.metal → the
    /// SwiftPM resource bundle. That last lookup expects <app>.bundle next to
    /// Contents/, which codesign refuses, so a packaged app must use the
    /// environment variable. Without it (and without default.metallib) the Metal
    /// backend fails to initialise and whisper silently runs on the CPU — roughly
    /// 3x slower on an M5 Pro.
    ///
    /// The GGML_METAL_PATH_RESOURCES branch is a no-op under `swift run`, where the
    /// shader stays inside the SwiftPM bundle and ggml's own lookup already works.
    private func configureGGMLResourcePath() {
        // Must precede any ggml/Metal call — see the doc comment above.
        setenv("GGML_METAL_TENSOR_DISABLE", "1", 1)
        print("[AppDelegate] GGML_METAL_TENSOR_DISABLE = 1 (default.metallib ships without tensor-API kernels)")

        guard let resources = Bundle.main.resourceURL else { return }
        let shader = resources.appendingPathComponent("ggml-metal.metal")
        guard FileManager.default.fileExists(atPath: shader.path) else {
            print("[AppDelegate] ggml-metal.metal not in Contents/Resources — leaving GGML_METAL_PATH_RESOURCES unset")
            return
        }
        setenv("GGML_METAL_PATH_RESOURCES", resources.path, 1)
        print("[AppDelegate] GGML_METAL_PATH_RESOURCES = \(resources.path)")
    }

    private func registerEmbeddedFonts() {
        let fontNames = [
            "Geist-Regular",
            "Geist-Medium",
            "Geist-SemiBold",
            "GeistMono-Regular",
            "GeistMono-Medium",
            "GeistMono-SemiBold"
        ]
        for name in fontNames {
            // build-app.sh flattens VoiceType_VoiceType.bundle into Contents/Resources,
            // so Bundle.main finds the TTFs in a packaged app; Bundle.module covers
            // `swift run`, where the resources stay in the SwiftPM bundle.
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                    ?? Bundle.module.url(forResource: name, withExtension: "ttf") else {
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

        // Re-apply initial prompt whenever language or custom vocabulary changes so the
        // bilingual seed is added/removed immediately — without requiring a model reload.
        Publishers.CombineLatest(
            AppSettings.shared.$language,
            AppSettings.shared.$customVocabulary
        )
        .removeDuplicates { $0 == $1 }
        .dropFirst()
        .sink { [weak self] _, _ in
            self?.applyInitialPrompt()
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

    /// Polls `isBusy` until it clears or `deadline` passes, sleeping
    /// `pollInterval` nanoseconds between checks rather than busy-waiting.
    ///
    /// Mirrors `TranscriptionService.shutdown()`'s own drain loop, but with a
    /// much longer deadline (`modelLoadDrainTimeout` vs `shutdownDrainTimeout`):
    /// `shutdown()` bounds its wait to keep app-quit latency reasonable and has
    /// a hard fallback (`_exit`) if it times out. This wait runs unobserved in
    /// the background while the app is otherwise idle, so it can afford to be
    /// generous with any legitimate (if long) transcription instead of giving
    /// up on the pending request too early.
    ///
    /// Exposed `internal` (not `private`) so `AppDelegateModelLoadDrainTests`
    /// can exercise the polling/deadline behaviour directly — the caller
    /// (`loadModel(for:)`) also touches `ModelManager.downloadModel` (real
    /// network) and `TranscriptionService.loadModel` (a real Whisper context),
    /// neither of which this test target can drive; see the "Coverage gaps"
    /// notes in ModelStatusTests.swift for the established precedent.
    ///
    /// - Returns: `true` once `isBusy()` reports false, `false` if `deadline`
    ///   passed while it was still true — callers must treat that as "give up
    ///   and log", never as license to retry in a tight loop.
    static func drain(
        until isBusy: () -> Bool,
        deadline: Date,
        pollInterval: UInt64 = 50_000_000
    ) async -> Bool {
        while isBusy() && Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return !isBusy()
    }

    /// How long `loadModel(for:)` waits for an in-flight transcription to
    /// finish before giving up on applying a pending model/accelerator-mode
    /// change. Much longer than `TranscriptionService.shutdownDrainTimeout`
    /// (5s) on purpose — see `drain`'s doc comment.
    private static let modelLoadDrainTimeout: TimeInterval = 60.0

    private func loadModel(for request: ModelLoadRequest) async {
        let model = request.model

        guard model.isCompatibleWithCurrentEngine else {
            AppLog.models.error("Refusing to load incompatible model \(model.rawValue, privacy: .public) — requires newer whisper.cpp engine")
            showErrorToast(
                title: "Model not supported",
                body: "\(model.displayName) requires a newer transcription engine. Select a different model in Settings."
            )
            return
        }

        let language = AppSettings.shared.language
        print("[AppDelegate] Reloading model: \(model.rawValue) with language: \(language.rawValue)")
        AppLog.models.notice("Reloading model \(model.rawValue, privacy: .public)")

        if !modelManager.isModelDownloaded(model: model) {
            print("[AppDelegate] Model not downloaded, downloading...")
            AppLog.models.notice("Downloading model \(model.rawValue, privacy: .public)")
            do {
                let includeCoreML = await CoreMLDownloadDecision.shouldInstall(for: model)
                try await modelManager.downloadModel(model: model, includeCoreML: includeCoreML)
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
        } else if request.downloadCoreMLIfNeeded && !modelManager.isCoreMLModelDownloaded(model: model),
                  await CoreMLDownloadDecision.shouldInstall(for: model) {
            print("[AppDelegate] CoreML not downloaded, downloading for GPU acceleration...")
            AppLog.models.notice("Downloading CoreML assets for \(model.rawValue, privacy: .public)")
            do {
                try await modelManager.downloadModel(model: model, includeCoreML: true)
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

        // Wait out an in-flight transcription instead of losing this request.
        // `unloadModel()`/`loadModel()` below both refuse to touch the context
        // while `isTranscribing` (UAF guard — see their doc comments in
        // TranscriptionService), and calling them unconditionally used to mean
        // the request — already popped off `pendingModelLoadRequest` — was
        // simply discarded on that guard, leaving the old model/accelerator in
        // place until the next reload or app restart (Codex review finding on
        // the M5 acceleration-policy work; pre-existing for plain model
        // switches too, just less visible there). See `drain`'s doc comment.
        if transcriptionService.isTranscribing {
            let deadline = Date().addingTimeInterval(Self.modelLoadDrainTimeout)
            let drained = await Self.drain(
                until: { [weak self] in self?.transcriptionService.isTranscribing ?? false },
                deadline: deadline
            )
            guard drained else {
                let message = "Could not apply change for \(model.rawValue): transcription still active after \(Self.modelLoadDrainTimeout)s wait"
                print("[AppDelegate] \(message)")
                AppLog.models.error("\(message, privacy: .public)")
                ErrorLogger.shared.log(message: message, category: "models", context: ["model": model.rawValue])
                return
            }

            // A newer request may have superseded this one while we waited.
            if hasNewerModelLoadRequest(than: request) {
                print("[AppDelegate] Skipping stale model load for \(model.rawValue) after drain wait")
                AppLog.models.notice("Skipping stale model load for \(model.rawValue, privacy: .public) after drain wait")
                return
            }
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
        transcriptionService.applyInitialPrompt()
    }

    /// Called when the user changes `AppSettings.shared.coreMLMode` — the
    /// Settings UI owns the subscription (see SettingsView) and calls this on
    /// every change. Routes through the same queued load path as a model
    /// switch (`scheduleModelLoad`/`pendingModelLoadRequest`): switching into
    /// `.on` needs `downloadCoreMLIfNeeded: true` so a missing encoder gets
    /// backfilled, and reusing the queue — rather than reloading inline —
    /// means a request arriving mid-transcription waits (via `drain` inside
    /// `loadModel(for:)`) for the current transcription to finish instead of
    /// yanking the model out from under it, exactly like an ordinary model
    /// switch does.
    func reloadModelForAccelerationModeChange() {
        scheduleModelLoad(AppSettings.shared.selectedModel, downloadCoreMLIfNeeded: true)
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
            hotkeyService.syncIsRecording(false)
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
            hotkeyService.syncIsRecording(false)
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

        // Generate a UUID-named destination in the audio directory before calling stop,
        // so the audio capture service can copy the raw CAF there before deletion.
        // Ensure the directory exists lazily (production path; test paths skip this).
        HistoryStore.shared.ensureAudioDirectoryExists()
        let audioFileName = "\(UUID().uuidString).caf"
        let audioDestination = HistoryStore.shared.audioDirectory
            .appendingPathComponent(audioFileName)

        let samples: [Float]
        var savedAudioPath: String?
        var savedAudioDuration: Double?

        do {
            let result = try audioCaptureService.stopRecordingRetaining(savingAudioTo: audioDestination)
            samples = result.0
            savedAudioPath = result.1 != nil ? audioFileName : nil
            savedAudioDuration = result.1
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
            let audioPathCapture = savedAudioPath
            let audioDurationCapture = savedAudioDuration
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                print("[AppDelegate] Transcription Task started, calling transcribeAndInject")
                await self.transcribeAndInject(
                    samples: samples,
                    audioPath: audioPathCapture,
                    audioDuration: audioDurationCapture
                )
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

    private func transcribeAndInject(
        samples: [Float],
        audioPath: String? = nil,
        audioDuration: Double? = nil
    ) async {
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

        // Trim is handled upstream by TranscriptionService.conditionallyTrim(_:),
        // gated on AppSettings.shared.trimWhitespaceAfterInsert. No secondary trim here.
        let text = transcriptionText ?? ""
        guard !text.isEmpty else {
            print("[AppDelegate] Transcription produced empty string — flashing emptyResult")
            AppLog.transcription.notice("Transcription produced empty text")
            voiceTypeWindow?.show(state: .emptyResult)
            Task { @MainActor [weak self] in
                let flashMs = insertedFlashDurationMs(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                try? await Task.sleep(for: .milliseconds(flashMs))
                self?.voiceTypeWindow?.hide()
                self?.appState = .idle
            }
            return
        }

        appState = .injecting

        // Capture target app name BEFORE injection — injection may shift focus.
        let targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let charCount = text.count

        // Record to history BEFORE injectText runs — task 1 (P1) fix. Previously
        // the entry was only appended after a successful injection, so a failed
        // insert (e.g. revoked Accessibility permission) silently dropped the
        // transcript and its audio file became an orphan on disk. Recording here
        // means the transcript survives regardless of outcome; recordOutcome
        // below fills in the actual insertSuccess once it's known.
        // Best-effort: flush failures are logged to ErrorLogger but never
        // surface to the user. DESIGN.md § Transcription History. Step 9.
        let historyEntryID = historyRecorder.recordPending(.init(
            text: text,
            targetAppName: targetAppName,
            targetAppBundleID: targetBundleID,
            language: AppSettings.shared.language.rawValue,
            audioPath: audioPath,
            model: AppSettings.shared.selectedModel.rawValue,
            audioDurationSeconds: audioDuration
        ))

        // Keep the app busy until the text is fully inserted, so the next hotkey
        // press cannot race with the paste/typing sequence.
        let injectionSucceeded = injectText(text, mode: AppSettings.shared.textInjectionMode)
        historyRecorder.recordOutcome(id: historyEntryID, insertSuccess: injectionSucceeded)

        if injectionSucceeded {
            // Flash `.inserted` for 400ms (per v5-inserted-state.html), then hide.
            // DESIGN.md § Reduced motion: shorten to 200ms when Reduce Motion is on.
            // appState stays non-idle during the flash so a hotkey press mid-flash
            // cannot pass canStartRecording() and start a new recording.
            voiceTypeWindow?.show(state: .inserted(charCount: charCount, targetAppName: targetAppName))
            Task { @MainActor [weak self] in
                let flashMs = insertedFlashDurationMs(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                try? await Task.sleep(for: .milliseconds(flashMs))
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

// MARK: - Reduce-motion helpers (testable free functions)

/// Returns the inserted/emptyResult flash duration in milliseconds.
/// DESIGN.md § Reduced motion: 200ms when Reduce Motion is on, 400ms otherwise.
func insertedFlashDurationMs(reduceMotion: Bool) -> Int {
    reduceMotion ? 200 : 400
}
