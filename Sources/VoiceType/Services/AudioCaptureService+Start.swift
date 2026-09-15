// AudioCaptureService+Start.swift — VoiceType
//
// Типы асинхронного старта (docs/plans/audio-start-hang.md), не требующие
// доступа к приватному состоянию AudioCaptureService — вынесены отдельным
// файлом по той же причине, что и AudioCaptureService+Samples.swift: главный
// файл упирался в порог file_length.

import AVFoundation
import Foundation

/// Идентичность попытки старта. `public`, потому что возвращается из
/// публичного метода: без этого сигнатура не скомпилируется.
///
/// Проверки одного лишь состояния сервиса недостаточно (docs/plans/
/// audio-start-hang.md, задача 1, требование 2): попытку A отменили или она
/// отвалилась по таймауту, пользователь начал B, и поздний результат A обязан
/// быть отброшен, а не принят за результат B.
public struct StartAttemptID: Equatable, Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}

/// Итог фоновой стартовой операции, отдаваемый `StartOperationRunner`.
enum StartOutcome {
    case success(StartedBundle)
    case failure(AudioCaptureError)
}

/// Идентичность ОДНОЙ сессии-кандидата внутри попытки старта — отдельно от
/// `StartAttemptID`, потому что одна попытка может породить НЕСКОЛЬКО
/// кандидатов подряд (primary, затем fallback на системный default): у
/// каждого своя сессия/observers, и прерывание одного не должно ни обрывать,
/// ни глушить (флагом «одно событие на запись») прерывания другого. Также
/// переживает завершение попытки: подтверждённая запись сверяется по этому
/// же ID и после того, как `currentAttempt` уже обнулён (P1-1/P1-3, код-ревью
/// docs/plans/audio-start-hang.md).
struct SessionCandidateID: Equatable {
    let value: Int
}

/// Ресурсы, которыми владеет ОДНА попытка старта, пока не подтверждён успех.
/// Cleanup заброшенной попытки трогает только объекты, на которые ссылается
/// конкретный экземпляр этого класса — не общие поля сервиса (docs/plans/
/// audio-start-hang.md, задача 1, требование 5). В `AudioCaptureService`
/// ресурсы мигрируют из bundle'а только в `finalizeSuccess`.
final class StartedBundle {
    let candidateID: SessionCandidateID
    let session: AVCaptureSession
    let output: AVCaptureAudioDataOutput
    let writer: AVAudioFile
    let writerFormat: AVAudioFormat
    let url: URL
    let deviceUID: String?
    let deviceName: String?
    let fallbackReason: DeviceFallbackReason?
    var observers: [NSObjectProtocol] = []

    init(
        candidateID: SessionCandidateID,
        session: AVCaptureSession,
        output: AVCaptureAudioDataOutput,
        writer: AVAudioFile,
        writerFormat: AVAudioFormat,
        url: URL,
        deviceUID: String?,
        deviceName: String?,
        fallbackReason: DeviceFallbackReason?
    ) {
        self.candidateID = candidateID
        self.session = session
        self.output = output
        self.writer = writer
        self.writerFormat = writerFormat
        self.url = url
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.fallbackReason = fallbackReason
    }

    /// Останавливает СОБСТВЕННУЮ сессию, снимает делегата и наблюдателей,
    /// удаляет временный файл. Общих полей сервиса не трогает — см.
    /// `AudioCaptureService.releaseSharedFields(ownedBy:)`. Идемпотентна.
    func localTeardown(deletingFile: Bool) {
        if session.isRunning {
            session.stopRunning()
        }
        output.setSampleBufferDelegate(nil, queue: nil)
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        if deletingFile {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Runner обязан вызвать `completion` РОВНО один раз, с любого потока — с
/// реальным AVFoundation-кодом в проде и подставным в тестах без живого
/// микрофона (docs/plans/audio-start-hang.md, задача 5).
typealias StartOperationCompletion = (StartOutcome) -> Void
typealias StartOperationRunner = (
    _ attemptID: StartAttemptID,
    _ preferredDeviceUID: String?,
    _ completion: @escaping StartOperationCompletion
) -> Void

/// Абстракция таймера watchdog — реальные часы в проде, управляемые вручную в
/// тестах (docs/plans/audio-start-hang.md, задача 5: «инъецируемый
/// планировщик watchdog»).
protocol WatchdogScheduling: AnyObject {
    func scheduleWatchdog(after seconds: TimeInterval, action: @escaping () -> Void) -> AnyObject
    func cancelWatchdog(_ token: AnyObject)
}

/// Watchdog на настоящих часах — `DispatchQueue.main.asyncAfter`.
final class RealWatchdogScheduler: WatchdogScheduling {
    func scheduleWatchdog(after seconds: TimeInterval, action: @escaping () -> Void) -> AnyObject {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    func cancelWatchdog(_ token: AnyObject) {
        (token as? DispatchWorkItem)?.cancel()
    }
}
