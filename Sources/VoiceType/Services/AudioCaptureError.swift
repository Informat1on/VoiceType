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
    case unexpectedCaptureFormat
    case framesDropped(received: Int, written: Int)
    case invalidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    case recordingFileMissing
    case recordingReadFailed(Error)
    case recordingConversionFailed

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
        case .unexpectedCaptureFormat:
            return "The microphone delivered audio in an unexpected format, so the recording was stopped instead of saved incorrectly."
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
        }
    }
}
