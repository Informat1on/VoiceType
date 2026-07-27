// AudioCaptureService.swift — VoiceType
//
// Захват микрофона: AVCaptureSession + AVCaptureAudioDataOutput.
//
// Почему не AVAudioRecorder, на котором это жило раньше: у него на macOS нет
// выбора входного устройства (AVAudioSession — iOS-only, а системное устройство
// по умолчанию менять из приложения нельзя, это глобальное состояние). Выбор
// микрофона — единственный рычаг продукта, который чинит ВХОД: Bluetooth-гарнитура
// в режиме HFP (8–16 кГц) съедает безударные слоги, и постобработка такое не
// лечит принципиально.
//
// Почему не AVAudioEngine, на котором это жило до апреля 2026 (f6879ca):
// installTap(bufferSize:) на macOS игнорируется, HAL отдаёт куски по 4800 кадров
// (100 мс). Волна по DESIGN обновляется каждые 50 мс — половина тиков была бы
// устаревшей. Плюс нативные 48 кГц и обязательная конверсия. Замеры 2026-07-27:
// docs/dev-diary/session7-artifacts/plan-v3-delta.md §0.
//
// Что даёт выбранный путь (замерено):
//   - куски по 165 кадров ≈ 10.3 мс, 94 вызова делегата в секунду;
//   - audioSettings отдают СРАЗУ 16 кГц моно int16 — конверсии в пути захвата нет;
//   - stopRunning() синхронный, поэтому публичный контракт остановки не меняется;
//   - выбор устройства штатный, тем же UID, что отдаёт CoreAudio;
//   - разрешения — та же AVCaptureDevice-модель, что уже в PermissionManager.
//
// Владение очередями (нарушение приводит к взаимной блокировке или к потере хвоста):
//   - sessionQueue — все блокирующие операции сессии;
//   - sampleQueue — ЕДИНОЛИЧНО владеет writer, счётчиком кадров и ошибкой записи;
//     делегат вызывается на ней и пишет файл непосредственно, без второго async;
//   - барьер на остановке идёт ДО закрытия generation, иначе уже поставленные в
//     очередь финальные буферы будут отброшены — это и есть потеря хвоста,
//     которую чинил b98eac9 в прежней engine-реализации;
//   - stopRecording() запрещено вызывать с sampleQueue.

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
    /// Прерывание принимается только в `.recording`; остальные схлопываются.
    private enum State {
        case idle, starting, recording, stopping
    }

    private let stateLock = NSLock()
    private var state: State = .idle
    private var generation = 0
    /// Одно событие прерывания на запись — см. `reportInterruption`.
    private var didReportInterruption = false

    // Живут только под sampleQueue.
    private var writer: AVAudioFile?
    private var writerFormat: AVAudioFormat?
    private var openGeneration: Int?
    /// Идентичность конкретного output, а не только номер поколения: сравнение
    /// `openGeneration == generation` само по себе ничего не защищает — callback
    /// от старого output, пришедший после нового старта, увидел бы уже равные
    /// значения и записался в новый файл.
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

    /// `preferredDeviceUID` = nil означает системное устройство по умолчанию —
    /// это и есть поведение до появления пикера, поэтому оно и дефолт.
    public func startRecording(preferredDeviceUID: String? = nil) throws {
        guard transition(to: .starting, from: [.idle]) else {
            throw AudioCaptureError.alreadyRecording
        }
        stateLock.lock()
        didReportInterruption = false
        stateLock.unlock()

        do {
            try beginSession(preferredDeviceUID: preferredDeviceUID)
        } catch {
            setState(.idle)
            throw error
        }

        setState(.recording)
        startMeterTimer()
    }

    private func beginSession(preferredDeviceUID: String?) throws {
        let systemDefaultUID = (try? AudioDeviceService.systemDefaultInputUID()) ?? nil
        let available = (try? AudioDeviceService.inputDevices().map(\.uid)) ?? []

        switch AudioDeviceResolver.resolve(
            preferredUID: preferredDeviceUID,
            availableUIDs: available,
            systemDefaultUID: systemDefaultUID
        ) {
        case .noDevice:
            throw AudioCaptureError.deviceUnavailable

        case .useSystemDefault(let uid):
            try configureAndStart(deviceUID: uid)
            publishDevice(uid, fallback: nil)

        case let .fallback(uid, reason):
            try configureAndStart(deviceUID: uid)
            publishDevice(uid, fallback: reason)

        case .usePreferred(let uid):
            do {
                try configureAndStart(deviceUID: uid)
                publishDevice(uid, fallback: nil)
            } catch {
                // Откат допускается ровно один раз и только на СИНХРОННЫЙ сбой
                // старта. Асинхронная runtime-ошибка откатом не считается — это
                // прерывание уже начавшейся записи, и незаметно перезапускать её
                // на другом устройстве после того, как человек заговорил, нельзя.
                guard let fallbackUID = systemDefaultUID else { throw error }
                try configureAndStart(deviceUID: fallbackUID)
                publishDevice(fallbackUID, fallback: .selectedDeviceFailed(uid: uid))
            }
        }
    }

    /// Синхронный сбой старта — это буквально: устройства с таким UID нет,
    /// `AVCaptureDeviceInput` бросил, вход или выход не добавляется, либо сессия
    /// не оказалась запущенной сразу после `startRunning()`. Ничего больше.
    private func configureAndStart(deviceUID: String?) throws {
        let device: AVCaptureDevice?
        if let deviceUID {
            device = AVCaptureDevice(uniqueID: deviceUID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw AudioCaptureError.deviceUnavailable }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioCaptureError.sessionConfigurationFailed(error)
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        let url = makeRecordingURL()
        // Явные commonFormat/interleaved обязательны: init(forWriting:settings:)
        // берёт float32 processing format даже когда on-disk settings просят
        // int16, и запись int16-буфера в такой writer недопустима.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioCaptureError.recordingFileMissing
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

        try sessionQueue.sync {
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                rollbackPartialStart(session: session, output: output, url: url)
                throw AudioCaptureError.sessionInputRejected
            }
            session.addInput(input)
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                rollbackPartialStart(session: session, output: output, url: url)
                throw AudioCaptureError.sessionOutputRejected
            }
            session.addOutput(output)
            session.commitConfiguration()

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

            // Наблюдатели — ДО startRunning(): между стартом и подпиской есть
            // окно, в котором сессия может остановиться, и её уведомление
            // некому было бы поймать — приложение осталось бы в .recording с
            // мёртвым микрофоном.
            installInterruptionObservers()

            session.startRunning()
            guard session.isRunning else {
                removeInterruptionObservers()
                rollbackPartialStart(session: session, output: output, url: url)
                throw AudioCaptureError.sessionDidNotStart
            }

            self.session = session
            self.recordingURL = url
        }
    }

    /// Единый откат для сбоя на полпути к записи. Без него частично собранная
    /// попытка оставляет за собой присоединённого делегата, открытый writer и
    /// временный файл, а следующая попытка (в том числе откат на системное
    /// устройство) начинается поверх этого мусора.
    private func rollbackPartialStart(
        session: AVCaptureSession,
        output: AVCaptureAudioDataOutput,
        url: URL
    ) {
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        sampleQueue.sync {
            openGeneration = nil
            activeOutput = nil
            writer = nil
            writerFormat = nil
        }
        try? FileManager.default.removeItem(at: url)
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
        // Обычная остановка и остановка по прерыванию идут через эту же функцию,
        // поэтому оба состояния допустимы: .stopping означает, что прерывание
        // уже перевело сюда, и второй остановки быть не должно.
        guard transition(to: .stopping, from: [.recording]) else {
            throw AudioCaptureError.notRecording
        }
        defer { setState(.idle) }

        stopMeterTimer()
        removeInterruptionObservers()

        sessionQueue.sync {
            session?.stopRunning()
            // Снять делегата, чтобы после барьера точно ничего не пришло.
            for output in session?.outputs ?? [] {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            session = nil
        }

        // Барьер ДО закрытия generation: буферы, уже поставленные в очередь,
        // обязаны попасть в файл.
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

        // Кадр, потерянный на любом guard делегата, исчез бы и из файла, и из
        // счётчика записанных — равенство «записано == в файле» такое не ловит.
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
        return CaptureResult(
            samples: samples,
            savedDuration: savedDuration,
            failure: failure.map { CaptureInterruption.writeFailed($0.localizedDescription) }
        )
    }

    // MARK: - Прерывания

    private func installInterruptionObservers() {
        let center = NotificationCenter.default

        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note)
            })
        }

        observe(AVCaptureSession.runtimeErrorNotification) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.reportInterruption(.runtimeError(error?.localizedDescription ?? "unknown"))
        }
        observe(AVCaptureSession.wasInterruptedNotification) { [weak self] _ in
            self?.reportInterruption(.sessionInterrupted)
        }
        // Сессия может просто перестать работать, не прислав ни runtime error,
        // ни interruption. Без этой подписки приложение осталось бы в
        // .recording с молчащим микрофоном до отпускания хоткея. Наша
        // собственная остановка сюда не попадает: наблюдатели снимаются до
        // stopRunning(), и состояние к тому моменту уже .stopping.
        observe(AVCaptureSession.didStopRunningNotification) { [weak self] _ in
            self?.reportInterruption(.sessionInterrupted)
        }
        observe(AVCaptureDevice.wasDisconnectedNotification) { [weak self] note in
            guard let self else { return }
            // Отключение постороннего устройства нас не касается.
            guard let disconnected = note.object as? AVCaptureDevice,
                  disconnected.uniqueID == self.activeDeviceUID || self.activeDeviceUID == nil else { return }
            self.reportInterruption(.deviceDisconnected)
        }
    }

    private func removeInterruptionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Владение остановкой при прерывании — ОДНО, и оно здесь: сервис только
    /// доставляет событие, а останавливает запись `AppDelegate` обычным
    /// `stopRecording()`. Единственный переход `.recording → .stopping` живёт
    /// внутри остановки, поэтому гонки «сервис уже перевёл в .stopping, а
    /// AppDelegate получил отказ» не существует.
    ///
    /// Доставляется РОВНО одно событие на запись: `runtimeError`, отключение
    /// устройства и сбой записи легко приходят пачкой, а пользователю нужно
    /// одно сообщение и одна остановка. Решение «транскрибировать частичное
    /// или показать ошибку» принимается после барьера по окончательному числу
    /// сэмплов, а не по счётчику в момент уведомления.
    private func reportInterruption(_ interruption: CaptureInterruption) {
        stateLock.lock()
        let accepted = (state == .recording) && !didReportInterruption
        if accepted { didReportInterruption = true }
        stateLock.unlock()
        guard accepted else { return }

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
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mSampleRate == targetSampleRate,
              asbd.pointee.mChannelsPerFrame == targetChannels,
              asbd.pointee.mBitsPerChannel == 16,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsPacked != 0 else {
            failCapture(.unexpectedCaptureFormat)
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
            failCapture(.unexpectedCaptureFormat)
            return
        }

        // Ровно, а не min(): короткий блок дал бы файл правильной длины с
        // частично невалидным содержимым — тишиной или мусором внутри речи.
        let expectedBytes = frameCount * MemoryLayout<Int16>.size
        guard length == expectedBytes else {
            failCapture(.unexpectedCaptureFormat)
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
