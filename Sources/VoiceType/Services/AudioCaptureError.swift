// AudioCaptureError.swift — VoiceType
//
// Ошибки захвата. Вынесены из AudioCaptureService отдельным файлом: тот и без
// них перевалил порог file_length, а список состояний, о которых приложение
// говорит пользователю, читается лучше отдельно от механики записи.

import AVFoundation

public enum AudioCaptureError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case formatCreationFailed
    case sessionConfigurationFailed(Error)
    case deviceUnavailable
    case sessionInputRejected
    case sessionOutputRejected
    case sessionDidNotStart
    /// `detail` называет, ЧТО именно не совпало. Без него три разных отказа в
    /// делегате — формат, нечитаемый блок-буфер, несовпавшая длина — давали в
    /// errors.log один и тот же текст, и причину приходилось добывать
    /// отдельным пробником (13.09.2026, Elgato Wave XLR MK.2).
    case unexpectedCaptureFormat(detail: String)
    case framesDropped(received: Int, written: Int)
    case invalidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    case recordingFileMissing
    case recordingReadFailed(Error)
    case recordingConversionFailed
    /// `startRunning()` не подтвердил старт в отведённый срок — CoreAudio сам
    /// ретраит бесконечно (замерено на Elgato Wave Link MicFX: Error 0x3C /
    /// ETIMEDOUT каждые ~14 с), и ждать его означает тот самый фриз, который
    /// docs/plans/audio-start-hang.md устраняет. `uid` — устройство, которое
    /// фоновая попытка уже разрешила (может отличаться от того, что выбрано в
    /// настройках, если сработал откат на системный default).
    case sessionStartTimedOut(uid: String?, seconds: Double)
    /// Предыдущая (отменённая/просроченная) попытка старта ещё не освободила
    /// ресурсы — новый старт отклонён немедленно, а не поставлен в очередь.
    case captureDeviceBusy
    /// Пользователь сам отменил старт (отпустил хоткей, пока сессия
    /// поднималась) — не ошибка, UI ничего не показывает. Кейс существует
    /// только затем, чтобы у отмены был однозначный терминальный исход.
    case startCancelled
    /// coreaudiod не отвечает: вызов CoreAudio не уложился в срок шлюза, либо
    /// шлюз уже в `.unresponsive`. Не про конкретное устройство — про всю
    /// аудиосистему macOS.
    case audioSystemUnresponsive

    public static func == (lhs: AudioCaptureError, rhs: AudioCaptureError) -> Bool {
        lhs.caseIdentifier == rhs.caseIdentifier
    }

    private var caseIdentifier: String {
        switch self {
        case .alreadyRecording: return "alreadyRecording"
        case .notRecording: return "notRecording"
        case .formatCreationFailed: return "formatCreationFailed"
        case .sessionConfigurationFailed: return "sessionConfigurationFailed"
        case .deviceUnavailable: return "deviceUnavailable"
        case .sessionInputRejected: return "sessionInputRejected"
        case .sessionOutputRejected: return "sessionOutputRejected"
        case .sessionDidNotStart: return "sessionDidNotStart"
        case .unexpectedCaptureFormat: return "unexpectedCaptureFormat"
        case .framesDropped: return "framesDropped"
        case .invalidInputFormat: return "invalidInputFormat"
        case .recordingFileMissing: return "recordingFileMissing"
        case .recordingReadFailed: return "recordingReadFailed"
        case .recordingConversionFailed: return "recordingConversionFailed"
        case .sessionStartTimedOut: return "sessionStartTimedOut"
        case .captureDeviceBusy: return "captureDeviceBusy"
        case .startCancelled: return "startCancelled"
        case .audioSystemUnresponsive: return "audioSystemUnresponsive"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "No active recording to stop."
        case .formatCreationFailed:
            return "Failed to create audio format."
        case .sessionConfigurationFailed(let error):
            return "Failed to configure audio session: \(error.localizedDescription)"
        case .deviceUnavailable:
            return "VoiceType could not find a microphone to record from. Check the input device in macOS and try again."
        case .sessionInputRejected:
            return "VoiceType could not attach the selected microphone to its capture session."
        case .sessionOutputRejected:
            return "VoiceType could not attach its audio output to the capture session."
        case .sessionDidNotStart:
            return "VoiceType started the microphone session but macOS did not run it. Check the active input device and try again."
        case let .unexpectedCaptureFormat(detail):
            return "The microphone delivered audio in an unexpected format, so the recording was stopped instead of saved incorrectly: \(detail)"
        case let .framesDropped(received, written):
            return "VoiceType received \(received) audio frames but could only store \(written), so the recording was incomplete."
        case let .invalidInputFormat(sampleRate, channelCount):
            return "Audio input is unavailable for VoiceType right now (sampleRate=\(sampleRate), channels=\(channelCount)). Check the active input device in macOS and try again."
        case .recordingFileMissing:
            return "VoiceType lost the temporary recording file before transcription could start."
        case .recordingReadFailed(let error):
            return "VoiceType could not read the recorded audio: \(error.localizedDescription)"
        case .recordingConversionFailed:
            return "VoiceType could not convert the recorded audio into the transcription format."
        case let .sessionStartTimedOut(uid, seconds):
            // Требование 15: НЕ запрашивать AVFoundation здесь — это вычисляется
            // лениво на любом потоке (в т.ч. main, при логировании в AppDelegate),
            // а разрешённое ИМЯ устройства уже есть на попытке (см.
            // `AudioCaptureService.handleWatchdogFired`, которое логирует его
            // отдельно). Текст ошибки называет только то, что несёт сам кейс.
            let deviceLabel = uid ?? "the system default microphone"
            return "VoiceType waited \(String(format: "%.1f", seconds))s for \(deviceLabel) to start, but macOS never confirmed the session. Check the active input device and try again."
        case .captureDeviceBusy:
            return "VoiceType is still releasing the previous microphone session. Wait a moment and try again."
        case .startCancelled:
            return "Recording start was cancelled before the microphone session finished opening."
        case .audioSystemUnresponsive:
            return "The macOS audio service (coreaudiod) isn't responding, so VoiceType can't reach any microphone. "
                + "Restart it in Terminal with \u{201c}sudo killall -9 coreaudiod\u{201d}, or restart your Mac."
        }
    }
}
