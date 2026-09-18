// AudioCaptureService+FileIO.swift — VoiceType
//
// docs/plans/coreaudiod-hang-resilience.md, задача 2: чтение/конвертация
// записанного файла и регистрация/снятие наблюдателей прерывания сессии.
// Вынесено из AudioCaptureService.swift отдельным файлом по той же причине,
// что и AudioCaptureService+Start.swift/+Samples.swift — главный файл упирался
// в порог file_length (ERROR на 1200 строк), а задаче 2 нужно было и добавить
// протокол ограниченной остановки, и вернуть 4 комментария шапки к исходной
// многострочной разбивке из HEAD (задача 1 склеила их в длинные строки, чтобы
// уложиться в тот же порог).
//
// Оба блока ниже двигают только СВОИ ресурсы (файл записи; observers
// конкретного bundle'а/сервиса) и не задевают состояние старта/остановки —
// поэтому их можно читать и проверять независимо от основного файла.
//
// Ослабленный доступ (private → internal) для вызовов отсюда:
//   - AudioCaptureService.targetSampleRate/targetChannels — нужны loadSamples/
//     convertBuffer здесь;
//   - AudioCaptureService.observers — нужен removeInterruptionObservers здесь;
//   - makeRecordingURL/loadSamples остаются вызываемыми из
//     configureAndStartAttempt/stopRecordingCore в главном файле.

import AVFoundation
import Foundation

extension AudioCaptureService {

    // MARK: - Файл

    func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceType-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    func loadSamples(from url: URL) throws -> [Float] {
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

    // MARK: - Наблюдатели прерываний

    func installInterruptionObservers(
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

    func removeInterruptionObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
