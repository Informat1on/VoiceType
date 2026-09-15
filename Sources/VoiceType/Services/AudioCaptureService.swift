// AudioCaptureService.swift — VoiceType
//
// Захват микрофона: AVCaptureSession + AVCaptureAudioDataOutput.
//
// Почему не AVAudioRecorder: на macOS нет выбора входного устройства — а это
// единственный рычаг продукта, чинящий ВХОД (Bluetooth HFP 8–16 кГц съедает
// безударные слоги, постобработка это не лечит).
//
// Почему не AVAudioEngine (жило тут до апреля 2026, f6879ca):
// installTap(bufferSize:) на macOS игнорируется, HAL отдаёт куски по 4800
// кадров (100 мс) при волне DESIGN раз в 50 мс. Замеры: docs/dev-diary/
// session7-artifacts/plan-v3-delta.md §0.
//
// Путь даёт (замерено): куски по 165 кадров ≈10.3 мс; audioSettings отдают
// СРАЗУ 16 кГц моно int16; stopRunning() синхронный; устройство — тот же UID,
// что у CoreAudio; разрешения — та же модель, что в PermissionManager.
//
// Владение очередями (нарушение приводит к взаимной блокировке или к потере хвоста):
//   - sessionQueue — все блокирующие операции сессии, включая блокирующий
//     `startRunning()`, поэтому старт уходит туда через `.async`, не `.sync`
//     с main (docs/plans/audio-start-hang.md, требование 1);
//   - sampleQueue — ЕДИНОЛИЧНО владеет writer, счётчиком кадров и ошибкой записи;
//     делегат вызывается на ней и пишет файл непосредственно, без второго async;
//   - барьер на остановке идёт ДО закрытия generation, иначе поставленные в
//     очередь финальные буферы будут отброшены (потеря хвоста, чинил b98eac9);
//   - stopRecording() запрещено вызывать с sampleQueue.
//
// Старт записи: устройство, не поднимающее IO-поток (Elgato Wave Link MicFX —
// CoreAudio ретраит `startRunning()` ~14 с), раньше вешало весь UI. Теперь
// `startRecording` возвращается немедленно, исход — асинхронно через
// `completion`, с watchdog 4 с по умолчанию.

import AVFoundation
import Combine
import Foundation

/// Почему запись прервалась не по воле пользователя.
enum CaptureInterruption: Sendable, Equatable {
    case deviceDisconnected
    case sessionInterrupted
    case runtimeError(String)
    case writeFailed(String)
}

/// Итог остановки записи. `failure` ненулевой, когда звук получен, но получен
/// не полностью, — вызывающий обязан сказать об этом пользователю.
struct CaptureResult {
    let samples: [Float]
    let savedDuration: Double?
    let failure: CaptureInterruption?
}

/// Почему пишем не с того устройства, которое выбрано в настройках.
enum DeviceFallbackReason: Equatable {
    /// Выбранного устройства сейчас нет в системе (гарнитуру отключили).
    case selectedDeviceUnavailable(uid: String)
    /// Устройство есть, но сессию на нём поднять не удалось.
    case selectedDeviceFailed(uid: String)
}

public final class AudioCaptureService: NSObject, ObservableObject {

    private let targetSampleRate: Double = 16000.0
    private let targetChannels: AVAudioChannelCount = 1

    private let sessionQueue = DispatchQueue(label: "com.voicetype.audiocapture.session")
    private let sampleQueue = DispatchQueue(label: "com.voicetype.audiocapture.sample", qos: .userInitiated)

    /// idle → starting → recording → stopping → idle.
    /// starting → abandoning → idle — отменённая или просроченная попытка,
    /// чьи фоновые ресурсы на `sessionQueue` ещё не освобождены: busy держится
    /// до конца cleanup, а не до момента резолва (docs/plans/audio-start-hang.md,
    /// задача 1, требование 6).
    /// Прерывание принимается в `.starting` (буферизуется на попытке) и в
    /// `.recording` (доставляется сразу); остальные состояния его игнорируют.
    private enum State {
        case idle, starting, recording, stopping, abandoning
    }

    private let stateLock = NSLock()
    private var state: State = .idle
    private var generation = 0
    /// Одно событие прерывания на запись — см. `reportInterruption`.
    private var didReportInterruption = false
    /// Причина прерывания, сохранённая под тем же замком. Возвращается в
    /// `CaptureResult` синхронно: уведомление на main может опоздать за
    /// обычной остановкой, и тогда неполная запись выглядела бы успешной.
    private var pendingInterruption: CaptureInterruption?

    // Живут только под sampleQueue.
    private var writer: AVAudioFile?
    private var writerFormat: AVAudioFormat?
    private var openGeneration: Int?
    /// Identity конкретного output, не только generation: иначе callback от
    /// старого output после нового старта увидел бы равные номера и
    /// записался бы в новый файл.
    private weak var activeOutput: AVCaptureAudioDataOutput?
    private var receivedFrames = 0
    private var writtenFrames = 0
    private var writeError: Error?
    private var meterSumOfSquares: Float = 0
    private var meterSampleCount = 0
    private var meterPeak: Float = 0

    private var session: AVCaptureSession?
    private var recordingURL: URL?
    private var meterTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Старт: попытки

    private final class StartAttempt {
        let id: StartAttemptID
        let preferredDeviceUID: String?
        let timeout: TimeInterval
        let acceptedAt = Date()
        var completion: ((Result<Void, AudioCaptureError>) -> Void)?
        var watchdogToken: AnyObject?
        var isResolved = false
        /// UID, разрешённый фоном (может отличаться от `preferredDeviceUID`
        /// — откат на системный default); для честного текста watchdog-ошибки.
        var resolvedDeviceUID: String?
        /// Имя устройства, разрешённое фоном вместе с UID — watchdog на main
        /// не спрашивает AVFoundation заново (P2-1).
        var resolvedDeviceName: String?

        init(
            id: StartAttemptID,
            preferredDeviceUID: String?,
            timeout: TimeInterval,
            completion: @escaping (Result<Void, AudioCaptureError>) -> Void
        ) {
            self.id = id
            self.preferredDeviceUID = preferredDeviceUID
            self.timeout = timeout
            self.completion = completion
        }
    }

    private var nextAttemptValue = 0
    private var currentAttempt: StartAttempt?

    private var nextCandidateValue = 0
    /// Идентичность ЖИВОЙ сессии-кандидата — в отличие от `currentAttempt`,
    /// НЕ обнуляется в `finalizeSuccess`: подтверждённая запись сверяется по
    /// identity весь свой срок жизни, до `stopRecordingCore` (P1-1).
    private var liveCandidateID: SessionCandidateID?

    /// Тестовый шов: дождаться фонового teardown, не блокируя main (P1-2).
    var sessionQueueForTesting: DispatchQueue { sessionQueue }

    /// Тестовый шов (требование 15): подменяет запись в errors.log — иначе
    /// тест писал бы в реальный лог пользователя. nil по умолчанию.
    var errorLogWriterForTesting: ((String) -> Void)?

    /// ErrorLogger — @MainActor; вызывающий уже на main (dispatchPrecondition),
    /// assumeIsolated доносит это до компилятора без async/await здесь.
    private func logToErrorFile(_ message: String) {
        if let errorLogWriterForTesting {
            errorLogWriterForTesting(message)
            return
        }
        MainActor.assumeIsolated {
            ErrorLogger.shared.log(message: message, category: "app")
        }
    }

    /// Тестовый шов (docs/plans/audio-start-hang.md, задача 5): подставной
    /// runner стартовой операции вместо реального AVFoundation-кода. `lazy`,
    /// а не IUO + присвоение после `super.init()`: замыканию нужен `self`,
    /// который недоступен до его готовности.
    lazy var startOperationRunner: StartOperationRunner = { [weak self] attemptID, preferredDeviceUID, completion in
        self?.performStartOperation(
            attemptID: attemptID,
            preferredDeviceUID: preferredDeviceUID,
            completion: completion
        )
    }
    /// Тестовый шов: подставной планировщик watchdog вместо реальных часов.
    var watchdogScheduler: WatchdogScheduling = RealWatchdogScheduler()

    @Published public var audioLevel: Float = 0.0

    /// Устройство, с которого идёт запись на самом деле. Настройка может
    /// указывать на другое — см. `fallbackReason`.
    @Published private(set) var activeDeviceUID: String?

    /// Ненулевое значение означает, что выбранное в настройках устройство не
    /// используется. Выбор в настройках при этом НЕ затирается: гарнитуру
    /// подключат обратно, и терять из-за этого настройку пользователя незачем.
    @Published private(set) var fallbackReason: DeviceFallbackReason?

    /// Вызывается на main, когда запись прервалась не по воле пользователя.
    /// Владелец — AppDelegate, ставит до `startRecording`.
    var onInterruption: ((CaptureInterruption) -> Void)?

    // MARK: - Старт

    /// Запускает запись. Возвращается немедленно; вызывать только с main.
    /// `completion` вызывается РОВНО один раз и всегда на main — включая отмену.
    ///
    /// ⚠️ `completion` НИКОГДА не вызывается inline, даже для немедленных
    /// отказов: он всегда ставится на main асинхронно, гарантированно ПОСЛЕ
    /// возврата метода — иначе вызывающий не успел бы сохранить
    /// `StartAttemptID`, и сверка identity в колбэке отбросила бы законный отказ.
    ///
    /// `timeout` — срок ВСЕЙ попытки, не только последнего шага. 4 с — CoreAudio
    /// сам таймаутится за 14 с, ждать его означает тот самый фриз, что мы устраняем.
    @discardableResult
    public func startRecording(
        preferredDeviceUID: String?,
        timeout: TimeInterval = 4.0,
        completion: @escaping (Result<Void, AudioCaptureError>) -> Void
    ) -> StartAttemptID {
        dispatchPrecondition(condition: .onQueue(.main))

        stateLock.lock()
        nextAttemptValue += 1
        let id = StartAttemptID(nextAttemptValue)

        guard state == .idle else {
            // .starting/.recording/.stopping — обычное «уже пишем».
            // .abandoning — резолвнута, но sessionQueue-работа не закончена:
            // до конца cleanup ресурс занят (требование 6).
            let failure: AudioCaptureError = (state == .abandoning) ? .captureDeviceBusy : .alreadyRecording
            stateLock.unlock()
            DispatchQueue.main.async { completion(.failure(failure)) }
            return id
        }

        let attempt = StartAttempt(
            id: id,
            preferredDeviceUID: preferredDeviceUID,
            timeout: timeout,
            completion: completion
        )
        currentAttempt = attempt
        state = .starting
        didReportInterruption = false
        pendingInterruption = nil
        stateLock.unlock()

        let watchdogToken = watchdogScheduler.scheduleWatchdog(after: timeout) { [weak self] in
            self?.handleWatchdogFired(attemptID: id)
        }
        stateLock.lock()
        attempt.watchdogToken = watchdogToken
        stateLock.unlock()

        startOperationRunner(id, preferredDeviceUID) { [weak self] outcome in
            self?.handleStartOutcome(outcome, attemptID: id)
        }

        return id
    }

    /// Отменяет незавершённый старт. Идемпотентна, безопасна в любом состоянии.
    /// Если старт ещё не разрешился, его `completion` получает
    /// `.failure(.startCancelled)` — ровно один раз, как и любой другой исход.
    func cancelPendingStart() {
        dispatchPrecondition(condition: .onQueue(.main))

        stateLock.lock()
        guard state == .starting, let attempt = currentAttempt else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard markResolved(attempt) else { return }

        stateLock.lock()
        state = .abandoning
        stateLock.unlock()

        if let token = attempt.watchdogToken {
            watchdogScheduler.cancelWatchdog(token)
        }
        let comp = attempt.completion
        attempt.completion = nil
        DispatchQueue.main.async { comp?(.failure(.startCancelled)) }
    }

    /// Атомарно помечает попытку разрешённой. Возвращает `true` ровно для
    /// ОДНОГО вызова на попытку — watchdog, `cancelPendingStart()` и исход
    /// фоновой операции соревнуются под одним замком (требование 3 задачи 1).
    @discardableResult
    private func markResolved(_ attempt: StartAttempt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !attempt.isResolved else { return false }
        attempt.isResolved = true
        return true
    }

    private func handleWatchdogFired(attemptID: StartAttemptID) {
        dispatchPrecondition(condition: .onQueue(.main))

        stateLock.lock()
        guard state == .starting, let attempt = currentAttempt, attempt.id == attemptID else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard markResolved(attempt) else { return }

        stateLock.lock()
        state = .abandoning
        let uid = attempt.resolvedDeviceUID ?? attempt.preferredDeviceUID
        let deviceLabel = attempt.resolvedDeviceName ?? uid ?? "system default" // P2-1: не спрашиваем AVFoundation тут
        stateLock.unlock()

        let elapsed = Date().timeIntervalSince(attempt.acceptedAt) // фактическая, не заданный порог (требование 13/15)

        AppLog.app.error(
            "Recording start watchdog fired after \(elapsed, format: .fixed(precision: 3), privacy: .public)s (device: \(deviceLabel, privacy: .public))"
        )
        // errors.log — то, что открывает Settings → Advanced (требование 15).
        // ОДИН раз: AppDelegate для .sessionStartTimedOut повторно не логирует.
        logToErrorFile(
            "Recording start timed out after \(String(format: "%.3f", elapsed))s (device: \(deviceLabel), uid: \(uid ?? "nil"))"
        )

        let comp = attempt.completion
        attempt.completion = nil
        comp?(.failure(.sessionStartTimedOut(uid: uid, seconds: elapsed)))
    }

    /// Читает и обновляет состояние попытки под замком — используется и
    /// фоном (`sessionQueue`), и main (watchdog/cancel).
    private func isAttemptStillActionable(_ id: StartAttemptID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let attempt = currentAttempt, attempt.id == id else { return false }
        return !attempt.isResolved
    }

    private func recordResolvedDeviceUID(_ uid: String?, for id: StartAttemptID) {
        stateLock.lock()
        if let attempt = currentAttempt, attempt.id == id {
            attempt.resolvedDeviceUID = uid
        }
        stateLock.unlock()
    }

    /// Имя сохраняется тут же, где уже есть живой `AVCaptureDevice` (требование
    /// 15/P2-1). Не `private` — тестовый шов: fake runner обходит
    /// `configureAndStartAttempt`, где это обычно вызывается.
    func recordResolvedDeviceName(_ name: String?, for id: StartAttemptID) {
        stateLock.lock()
        if let attempt = currentAttempt, attempt.id == id {
            attempt.resolvedDeviceName = name
        }
        stateLock.unlock()
    }

    private func allocateCandidateID() -> SessionCandidateID {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextCandidateValue += 1
        return SessionCandidateID(value: nextCandidateValue)
    }

    /// Делает `candidateID` живым: цель сверки identity для наблюдателей, и
    /// «одно прерывание на запись» — per-candidate, не per-attempt (P1-3):
    /// primary не должен ни обрывать fallback, ни расходовать на себя его
    /// флаг. Вызывается из `configureAndStartAttempt` до подписки. Не
    /// `private` — тестовый шов (см. AudioStartTimeoutTests).
    func beginCandidate(_ candidateID: SessionCandidateID) {
        stateLock.lock()
        liveCandidateID = candidateID
        didReportInterruption = false
        pendingInterruption = nil
        stateLock.unlock()
    }

    /// Снимает claim на разделяемые sampleQueue-поля, если они всё ещё
    /// принадлежат этому bundle (сверка по identity output). Никогда не
    /// трогает поля, которые уже перешли к более новой попытке (требование 5).
    private func releaseSharedFields(ownedBy bundle: StartedBundle) {
        sampleQueue.sync {
            guard activeOutput === bundle.output else { return }
            activeOutput = nil
            writer = nil
            writerFormat = nil
            openGeneration = nil
        }
    }

    /// Блокирующий (`stopRunning()` на зависшем устройстве) — НЕ на main (P1-2).
    private func abandon(_ bundle: StartedBundle) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        releaseSharedFields(ownedBy: bundle)
        bundle.localTeardown(deletingFile: true)
    }

    /// Безопасен к вызову с main: teardown на sessionQueue, busy снимается по его завершении (требование 6).
    private func abandonAsync(_ bundle: StartedBundle, releasingBusyFor attemptID: StartAttemptID) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.abandon(bundle)
            DispatchQueue.main.async {
                self.stateLock.lock()
                if self.currentAttempt?.id == attemptID {
                    self.currentAttempt = nil
                    self.state = .idle
                }
                self.stateLock.unlock()
            }
        }
    }

    private func performStartOperation(
        attemptID: StartAttemptID,
        preferredDeviceUID: String?,
        completion: @escaping StartOperationCompletion
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.beginSessionAttempt(preferredDeviceUID: preferredDeviceUID, attemptID: attemptID)
            completion(outcome)
        }
    }

    private func handleStartOutcome(_ outcome: StartOutcome, attemptID: StartAttemptID) {
        // Гарантированный хоп на main: контракт запрещает вызывать completion
        // инлайн, даже если runner (в т.ч. тестовый fake) отвечает синхронно.
        DispatchQueue.main.async { [weak self] in
            self?.finishStartOutcome(outcome, attemptID: attemptID)
        }
    }

    private func finishStartOutcome(_ outcome: StartOutcome, attemptID: StartAttemptID) {
        dispatchPrecondition(condition: .onQueue(.main))

        stateLock.lock()
        guard let attempt = currentAttempt, attempt.id == attemptID else {
            stateLock.unlock()
            // Не должно быть достижимо при busy-гейте; fail-safe: чужой
            // bundle не публикуем, чистим в фоне (P1-2, не блокирует main).
            if case .success(let bundle) = outcome {
                sessionQueue.async { [weak self] in self?.abandon(bundle) }
            }
            return
        }
        stateLock.unlock()

        let wonRace = markResolved(attempt)

        switch outcome {
        case .failure(let error):
            stateLock.lock()
            currentAttempt = nil
            state = .idle
            stateLock.unlock()
            guard wonRace else { return }
            let comp = attempt.completion
            attempt.completion = nil
            comp?(.failure(error))

        case .success(let bundle):
            guard wonRace else {
                // Требования 4/14: уже разрешена watchdog'ом/cancel — не
                // финализируем, только освобождаем ресурсы bundle'а. Teardown
                // и снятие busy — в фоне (P1-2), main не ждёт.
                abandonAsync(bundle, releasingBusyFor: attemptID)
                return
            }
            finalizeSuccess(bundle: bundle, attempt: attempt)
        }
    }

    /// Требование 16: переход в `.recording`, публикация и `completion` — одним
    /// неразрывным блоком на main, иначе прерывание проскочило бы между ними.
    private func finalizeSuccess(bundle: StartedBundle, attempt: StartAttempt) {
        dispatchPrecondition(condition: .onQueue(.main))

        if let token = attempt.watchdogToken {
            watchdogScheduler.cancelWatchdog(token)
        }

        // sampleQueue-поля уже привязаны в configureAndStartAttempt; тут — только
        // session/recordingURL/observers (не sampleQueue-protected).
        self.session = bundle.session
        self.recordingURL = bundle.url
        self.observers = bundle.observers

        let elapsed = Date().timeIntervalSince(attempt.acceptedAt) // требование 13
        let deviceLabel = bundle.deviceName ?? bundle.deviceUID ?? "system default"
        AppLog.app.notice(
            "Recording session started in \(String(format: "%.3f", elapsed), privacy: .public)s (device: \(deviceLabel, privacy: .public))"
        )

        stateLock.lock()
        state = .recording
        currentAttempt = nil
        liveCandidateID = bundle.candidateID // P1-1: переживает очистку currentAttempt
        let bufferedInterruption = pendingInterruption // P1-3: per-candidate, сброшен в beginCandidate
        stateLock.unlock()

        publishDevice(bundle.deviceUID, fallback: bundle.fallbackReason)
        startMeterTimer()

        let comp = attempt.completion
        attempt.completion = nil
        comp?(.success(()))

        // Буферизованное прерывание — сразу после success; уже на main.
        if let bufferedInterruption {
            onInterruption?(bufferedInterruption)
        }
    }

    /// Без throws, с fallback, запрещённым для заброшенной попытки (требование
    /// 14). На `sessionQueue` (вызывающий уже там).
    private func beginSessionAttempt(
        preferredDeviceUID: String?,
        attemptID: StartAttemptID
    ) -> StartOutcome {
        let systemDefaultUID = try? AudioDeviceService.systemDefaultInputUID()
        let available = (try? AudioDeviceService.inputDevices().map(\.uid)) ?? []

        switch AudioDeviceResolver.resolve(
            preferredUID: preferredDeviceUID,
            availableUIDs: available,
            systemDefaultUID: systemDefaultUID
        ) {
        case .noDevice:
            return .failure(.deviceUnavailable)

        case .useSystemDefault(let uid):
            recordResolvedDeviceUID(uid, for: attemptID)
            return configureAndStartAttempt(deviceUID: uid, fallback: nil, attemptID: attemptID)

        case let .fallback(uid, reason):
            recordResolvedDeviceUID(uid, for: attemptID)
            return configureAndStartAttempt(deviceUID: uid, fallback: reason, attemptID: attemptID)

        case .usePreferred(let uid):
            recordResolvedDeviceUID(uid, for: attemptID)
            let primary = configureAndStartAttempt(deviceUID: uid, fallback: nil, attemptID: attemptID)
            guard case .failure = primary else { return primary }

            // Откат — один раз, только на синхронный сбой и если попытка ещё
            // актуальна (требование 14): не поднимать вторую сессию для мёртвой.
            guard let fallbackUID = systemDefaultUID, isAttemptStillActionable(attemptID) else {
                return primary
            }
            recordResolvedDeviceUID(fallbackUID, for: attemptID)
            return configureAndStartAttempt(
                deviceUID: fallbackUID,
                fallback: .selectedDeviceFailed(uid: uid),
                attemptID: attemptID
            )
        }
    }

    /// Синхронный сбой старта: устройства нет, вход/выход не добавляется, либо
    /// сессия не запустилась. Блокирующий `startRunning()` живёт здесь —
    /// вызывающий уже на `sessionQueue` (требование 1: main не блокируется).
    private func configureAndStartAttempt(
        deviceUID: String?,
        fallback: DeviceFallbackReason?,
        attemptID: StartAttemptID
    ) -> StartOutcome {
        let device: AVCaptureDevice?
        if let deviceUID {
            device = AVCaptureDevice(uniqueID: deviceUID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { return .failure(.deviceUnavailable) }
        recordResolvedDeviceName(device.localizedName, for: attemptID)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failure(.sessionConfigurationFailed(error))
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            return .failure(.formatCreationFailed)
        }

        let url = makeRecordingURL()
        // Явные commonFormat/interleaved обязательны: init(forWriting:settings:)
        // берёт float32 processing format, даже когда settings просят int16.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            return .failure(.recordingFileMissing)
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: Int(targetChannels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            try? FileManager.default.removeItem(at: url)
            return .failure(.sessionInputRejected)
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            try? FileManager.default.removeItem(at: url)
            return .failure(.sessionOutputRejected)
        }
        session.addOutput(output)
        session.commitConfiguration()

        let candidateID = allocateCandidateID()
        let bundle = StartedBundle(
            candidateID: candidateID,
            session: session,
            output: output,
            writer: file,
            writerFormat: format,
            url: url,
            deviceUID: deviceUID,
            deviceName: device.localizedName,
            fallbackReason: fallback
        )

        beginCandidate(candidateID) // живой ДО подписки (P1-3: primary не глушит fallback)

        // sampleQueue-поля — ДО startRunning() (требование 12): буферы могут
        // прийти до подписки делегата. Один bundle — busy-гейт не пропустит
        // новый старт, пока эти поля не освобождены (требования 4-6).
        sampleQueue.sync {
            generation += 1
            openGeneration = generation
            activeOutput = output
            writer = file
            writerFormat = format
            receivedFrames = 0
            writtenFrames = 0
            writeError = nil
            meterSumOfSquares = 0
            meterSampleCount = 0
            meterPeak = 0
        }

        // Наблюдатели — ДО startRunning(), привязаны к этой сессии и кандидату
        // (требования 9/17; P1-1/P1-3 — candidateID, не attemptID).
        installInterruptionObservers(session: session, candidateID: candidateID, into: bundle)

        session.startRunning()
        guard session.isRunning else {
            abandon(bundle)
            return .failure(.sessionDidNotStart)
        }

        return .success(bundle)
    }

    private func publishDevice(_ uid: String?, fallback: DeviceFallbackReason?) {
        DispatchQueue.main.async {
            self.activeDeviceUID = uid
            self.fallbackReason = fallback
        }
    }

    // MARK: - Остановка

    public func stopRecording() throws -> [Float] {
        try stopRecordingCore(savingAudioTo: nil).samples
    }

    /// Останавливает запись, возвращает сэмплы и, если попросили, копирует
    /// сырой файл в `saveURL` до удаления.
    ///
    /// `failure` возвращается ВМЕСТЕ с сэмплами, а не только через
    /// `onInterruption`: асинхронный канал проигрывает гонку, когда сбой записи
    /// приходит ровно в тот момент, когда пользователь уже остановил запись
    /// сам, — тогда вызывающий получил бы неполный звук как обычный успех.
    func stopRecordingRetaining(savingAudioTo saveURL: URL) throws -> CaptureResult {
        try stopRecordingCore(savingAudioTo: saveURL)
    }

    @discardableResult
    private func stopRecordingCore(savingAudioTo saveURL: URL?) throws -> CaptureResult {
        // Обычная остановка и остановка по прерыванию идут через эту же функцию.
        // Инвариант: к моменту .recording фоновая стартовая операция уже вышла
        // из sessionQueue (финализация — только после runner'а, требование 10),
        // поэтому `sessionQueue.sync` ниже безопасен.
        guard transition(to: .stopping, from: [.recording]) else {
            throw AudioCaptureError.notRecording
        }
        defer { setState(.idle) }

        stopMeterTimer()
        removeInterruptionObservers()

        stateLock.lock()
        let sessionInterruption = pendingInterruption
        // Запись действительно закончилась — снимаем identity, чтобы её
        // случайно не сверило с ней позднее уведомление (P1-1 hygiene).
        liveCandidateID = nil
        stateLock.unlock()

        sessionQueue.sync {
            session?.stopRunning()
            // Снять делегата, чтобы после барьера точно ничего не пришло.
            for output in session?.outputs ?? [] {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            session = nil
        }

        // Барьер ДО закрытия generation: буферы в очереди обязаны попасть в файл.
        var failure: Error?
        var received = 0
        var written = 0
        sampleQueue.sync {
            failure = writeError
            received = receivedFrames
            written = writtenFrames
            openGeneration = nil
            activeOutput = nil
            // Явного close() здесь быть не может: AVAudioFile.close() появился
            // только в macOS 15, а цель проекта — macOS 13. Освобождение делает
            // ту же работу детерминированно: sampleQueue — единственный владелец
            // ссылки, поэтому writer уничтожается ровно здесь, дописывая
            // заголовок до того, как файл будет прочитан.
            writer = nil
            writerFormat = nil
        }

        // Кадр, потерянный на guard'е делегата, исчез бы и из файла, и из счётчика.
        if failure == nil, received != written {
            failure = AudioCaptureError.framesDropped(received: received, written: written)
        }

        let url = recordingURL
        recordingURL = nil
        DispatchQueue.main.async { self.audioLevel = 0 }

        guard let url else { throw AudioCaptureError.recordingFileMissing }

        // Даже при сбое записи файл сначала читается. Уже записанное принадлежит
        // человеку, который это произнёс: выбросить его вместе с ошибкой значит
        // нарушить то самое правило «есть звук — транскрибируем частичное»,
        // ради которого заведён CaptureInterruptionDecision. Ошибка при этом не
        // теряется — о прерывании AppDelegate уже уведомлён.
        var samples: [Float] = []
        var loadFailure: Error?
        do {
            samples = try loadSamples(from: url)
        } catch {
            loadFailure = error
        }

        if samples.isEmpty {
            try? FileManager.default.removeItem(at: url)
            if let failure { throw AudioCaptureError.recordingReadFailed(failure) }
            if let loadFailure { throw loadFailure }
            return CaptureResult(samples: [], savedDuration: nil, failure: nil)
        }

        if let failure {
            print("[AudioCapture] Keeping \(samples.count) samples despite capture failure: \(failure)")
        }

        var savedDuration: Double?
        if let destination = saveURL {
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                if !samples.isEmpty {
                    savedDuration = Double(samples.count) / targetSampleRate
                }
            } catch {
                // Нефатально: сбой сохранения аудио для истории не должен
                // мешать транскрипции. Сбой самого захвата — фатален.
                print("[AudioCapture] Failed to save eval audio: \(error)")
            }
        }

        try? FileManager.default.removeItem(at: url)
        // Прерывание сессии важнее сбоя записи: оно называет первопричину,
        // а сбой записи часто лишь её следствие.
        return CaptureResult(
            samples: samples,
            savedDuration: savedDuration,
            failure: sessionInterruption
                ?? failure.map { CaptureInterruption.writeFailed($0.localizedDescription) }
        )
    }

    // MARK: - Прерывания

    private func installInterruptionObservers(
        session: AVCaptureSession,
        candidateID: SessionCandidateID,
        into bundle: StartedBundle
    ) {
        let center = NotificationCenter.default

        // queue: nil — намеренно. С `queue: .main` блок планируется на main, а
        // подписка ставится из-под sessionQueue, где main может быть занят
        // другой работой: обработчику main и не нужен — reportInterruption
        // сам уходит на него, когда вызван не оттуда.
        func observe(_ name: Notification.Name, object: Any?, _ handler: @escaping (Notification) -> Void) {
            bundle.observers.append(center.addObserver(forName: name, object: object, queue: nil) { note in
                handler(note)
            })
        }

        // object: session — иначе уведомление ЛЮБОЙ сессии, включая чужую,
        // достигало бы этого обработчика (требование 9). requiredCandidateID
        // в reportInterruption — вторая проверка, по КОНКРЕТНОМУ кандидату,
        // не по всей попытке (P1-3): сессия могла устареть и сама по себе.
        observe(AVCaptureSession.runtimeErrorNotification, object: session) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.reportInterruption(.runtimeError(error?.localizedDescription ?? "unknown"), requiredCandidateID: candidateID)
        }
        observe(AVCaptureSession.wasInterruptedNotification, object: session) { [weak self] _ in
            self?.reportInterruption(.sessionInterrupted, requiredCandidateID: candidateID)
        }
        // Сессия может просто перестать работать без runtime error/interruption;
        // наша собственная остановка сюда не попадает (наблюдатели снимаются
        // до stopRunning()).
        observe(AVCaptureSession.didStopRunningNotification, object: session) { [weak self] _ in
            self?.reportInterruption(.sessionInterrupted, requiredCandidateID: candidateID)
        }
        // object: nil — шлёт устройство, не сессия; фильтруется вручную по
        // UID ИМЕННО этого кандидата (bundle.deviceUID), не по глобальному
        // activeDeviceUID — тот мог уже принадлежать следующей записи.
        observe(AVCaptureDevice.wasDisconnectedNotification, object: nil) { [weak self] note in
            guard let disconnected = note.object as? AVCaptureDevice,
                  disconnected.uniqueID == bundle.deviceUID || bundle.deviceUID == nil else { return }
            self?.reportInterruption(.deviceDisconnected, requiredCandidateID: candidateID)
        }
    }

    private func removeInterruptionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Доставляется РОВНО одно событие на запись — решение «транскрибировать
    /// частичное или показать ошибку» принимается позже, по барьеру.
    ///
    /// `requiredCandidateID` нил — вызов из делегата sample buffer: identity
    /// уже подтверждена `activeOutput`/`openGeneration` выше по стеку. Не-нил
    /// — вызов из наблюдателя КОНКРЕТНОГО кандидата (требования 9/17,
    /// P1-1/P1-3): событие может прийти ещё в `.starting` (буферизуется в
    /// `pendingInterruption`, доставляется `finalizeSuccess`). Сверка — с
    /// `liveCandidateID`: переживает очистку `currentAttempt` (P1-1) и
    /// меняется на каждого нового кандидата внутри одной попытки, primary/
    /// fallback (P1-3).
    ///
    /// Не `private` — тестовый шов (задача 5 плана, п.8/11; код-ревью п.1-2):
    /// без живой AVCaptureSession тесты не спровоцируют уведомление, но могут
    /// проверить identity-сверку напрямую.
    func reportInterruption(
        _ interruption: CaptureInterruption,
        requiredCandidateID: SessionCandidateID? = nil
    ) {
        stateLock.lock()
        let identityOK = requiredCandidateID == nil || requiredCandidateID == liveCandidateID
        let acceptableState = (state == .recording) || (state == .starting && requiredCandidateID != nil)
        let accepted = identityOK && acceptableState && !didReportInterruption
        var deliverNow = false
        if accepted {
            didReportInterruption = true
            pendingInterruption = interruption
            deliverNow = (state == .recording)
        }
        stateLock.unlock()
        guard accepted, deliverNow else { return }

        if Thread.isMainThread {
            onInterruption?(interruption)
        } else {
            DispatchQueue.main.async { self.onInterruption?(interruption) }
        }
    }

    // MARK: - Состояние

    private func transition(to newState: State, from allowed: [State]) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard allowed.contains(state) else { return false }
        state = newState
        return true
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }

    // MARK: - Уровень для волны

    /// Каденция 50 мс сохранена намеренно: это тик, на который рассчитана волна
    /// в DESIGN, и менять её эта задача не вправе. Делегат лишь копит RMS и пик,
    /// а публикует их таймер на main — по той же формуле, что была у recorder.
    private func startMeterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var average: Float = 0
            var peak: Float = 0
            self.sampleQueue.sync {
                if self.meterSampleCount > 0 {
                    average = (self.meterSumOfSquares / Float(self.meterSampleCount)).squareRoot()
                }
                peak = self.meterPeak
                self.meterSumOfSquares = 0
                self.meterSampleCount = 0
                self.meterPeak = 0
            }
            let avgLevel = self.normalizedDecibelLevel(Self.decibels(from: average))
            let peakLevel = self.normalizedDecibelLevel(Self.decibels(from: peak))
            self.audioLevel = min(max(avgLevel * 0.7 + peakLevel * 0.6, 0), 1.0)
        }
        meterTimer = timer
        timer.resume()
    }

    private func stopMeterTimer() {
        meterTimer?.setEventHandler {}
        meterTimer?.cancel()
        meterTimer = nil
    }

    private static func decibels(from amplitude: Float) -> Float {
        guard amplitude > 0 else { return -160 }
        return 20 * log10(amplitude)
    }

    private func normalizedDecibelLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        if decibels <= -80 { return 0 }
        return pow(10, decibels / 20)
    }

    // MARK: - Файл

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceType-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private func loadSamples(from url: URL) throws -> [Float] {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sourceFormat = audioFile.processingFormat

            guard Self.isUsableInputFormat(sourceFormat) else {
                throw AudioCaptureError.invalidInputFormat(
                    sampleRate: sourceFormat.sampleRate,
                    channelCount: sourceFormat.channelCount
                )
            }
            guard audioFile.length > 0 else { return [] }

            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                throw AudioCaptureError.formatCreationFailed
            }

            try audioFile.read(into: sourceBuffer)

            if !Self.requiresConversion(
                from: sourceFormat,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            ) {
                return Self.normalizedSamples(from: sourceBuffer) ?? []
            }

            let convertedBuffer = try convertBuffer(sourceBuffer)
            return Self.normalizedSamples(from: convertedBuffer) ?? []
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            throw AudioCaptureError.recordingReadFailed(error)
        }
    }

    private func convertBuffer(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw AudioCaptureError.recordingConversionFailed
        }

        let estimatedFrameCount = max(
            AVAudioFrameCount(
                Double(sourceBuffer.frameLength) * (targetSampleRate / max(sourceBuffer.format.sampleRate, 1))
            ) + 1024,
            1024
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedFrameCount
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        var didProvideInput = false
        var convertedSamples: [Float] = []

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                guard !didProvideInput else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if status == .error {
                throw AudioCaptureError.recordingConversionFailed
            }

            if outputBuffer.frameLength > 0 {
                convertedSamples.append(contentsOf: Self.normalizedSamples(from: outputBuffer) ?? [])
                outputBuffer.frameLength = 0
            }

            if status != .haveData {
                break
            }
        }

        guard let finalBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(max(convertedSamples.count, 1))
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        finalBuffer.frameLength = AVAudioFrameCount(convertedSamples.count)
        guard let channelData = finalBuffer.floatChannelData else {
            throw AudioCaptureError.recordingConversionFailed
        }

        for (index, sample) in convertedSamples.enumerated() {
            channelData[0][index] = sample
        }

        return finalBuffer
    }
}

// MARK: - Делегат

extension AudioCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Уже на sampleQueue — пишем прямо здесь, без второго async, иначе
        // барьер на остановке перестанет что-либо гарантировать.
        //
        // Сверяется ИДЕНТИЧНОСТЬ output, а не только номер поколения: буфер от
        // прошлой записи, догнавший нас после нового старта, увидел бы уже
        // равные номера и дописался бы в чужой файл.
        guard let activeOutput, output === activeOutput,
              openGeneration == generation,
              let writer, let format = writerFormat else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }
        receivedFrames += frameCount

        // Формат обязан быть ровно тем, что запрошен в audioSettings. «Терпимой»
        // записи чужого формата здесь нет: writer сконфигурирован под int16,
        // и подсунуть ему что-то другое значит записать мусор под видом речи.
        // Сами критерии — в CaptureFormatValidator: там же объяснено, почему
        // упаковка проверяется по геометрии кадра, а не по флагу IsPacked.
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            failCapture(.unexpectedCaptureFormat(detail: "buffer carries no audio format description"))
            return
        }
        if let reason = CaptureFormatValidator.rejectionReason(
            for: asbd.pointee,
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels
        ) {
            failCapture(.unexpectedCaptureFormat(detail: reason))
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            failCapture(.formatCreationFailed)
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer, let destination = buffer.int16ChannelData else {
            failCapture(.unexpectedCaptureFormat(detail: "buffer data could not be read"))
            return
        }

        // Ровно, а не min(): короткий блок дал бы файл правильной длины с
        // частично невалидным содержимым — тишиной или мусором внутри речи.
        let expectedBytes = frameCount * MemoryLayout<Int16>.size
        guard length == expectedBytes else {
            failCapture(.unexpectedCaptureFormat(
                detail: "buffer holds \(length) bytes, expected \(expectedBytes) for \(frameCount) frames"
            ))
            return
        }
        memcpy(destination[0], pointer, expectedBytes)

        accumulateLevel(from: destination[0], frameCount: frameCount)

        do {
            try writer.write(from: buffer)
            writtenFrames += frameCount
        } catch {
            writeError = error
            reportInterruption(.writeFailed(error.localizedDescription))
        }
    }

    /// Первая ошибка захвата сохраняется и поднимает прерывание; последующие
    /// буферы уже ничего не перезаписывают — важна именно первая причина.
    private func failCapture(_ error: AudioCaptureError) {
        guard writeError == nil else { return }
        writeError = error
        reportInterruption(.writeFailed(error.localizedDescription ?? "capture failed"))
    }

    private func accumulateLevel(from samples: UnsafeMutablePointer<Int16>, frameCount: Int) {
        let scale = Float(Int16.max)
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for index in 0..<frameCount {
            let value = abs(Float(samples[index]) / scale)
            sumOfSquares += value * value
            if value > peak { peak = value }
        }
        meterSumOfSquares += sumOfSquares
        meterSampleCount += frameCount
        meterPeak = max(meterPeak, peak)
    }
}
