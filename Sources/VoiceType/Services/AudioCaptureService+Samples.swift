// AudioCaptureService+Samples.swift — VoiceType
//
// Чистые преобразования сэмплов: нужна ли конверсия, как свести каналы, годен
// ли формат. Приватного состояния захвата не касаются, поэтому живут отдельно
// от него — и поэтому же их можно проверять тестами без микрофона.

import AVFoundation

extension AudioCaptureService {

    // MARK: - Чистые помощники (используются тестами и путём чтения файла)

    static func requiresConversion(
        from inputFormat: AVAudioFormat,
        targetSampleRate: Double = 16000.0,
        targetChannels: AVAudioChannelCount = 1
    ) -> Bool {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            return true
        }

        return inputFormat.sampleRate != outputFormat.sampleRate
            || inputFormat.channelCount != outputFormat.channelCount
            || inputFormat.commonFormat != outputFormat.commonFormat
            || inputFormat.isInterleaved != outputFormat.isInterleaved
    }

    static func normalizedSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            return averageChannels(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                channelData[channel][frame]
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            let scale = Float(Int16.max)
            return averageChannels(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                Float(channelData[channel][frame]) / scale
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return nil }
            let scale = Float(Int32.max)
            return averageChannels(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                Float(channelData[channel][frame]) / scale
            }
        default:
            return nil
        }
    }

    private static func averageChannels(
        frameCount: Int,
        channelCount: Int,
        sampleAt: (_ channel: Int, _ frame: Int) -> Float
    ) -> [Float] {
        if channelCount == 1 {
            return (0..<frameCount).map { sampleAt(0, $0) }
        }

        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sampleAt(channel, frame)
            }
            return sum / Float(channelCount)
        }
    }

    static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }
}
