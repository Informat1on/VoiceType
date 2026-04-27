import AVFoundation
import Foundation
import Combine

public final class AudioCaptureService: ObservableObject {

    private let targetSampleRate: Double = 16000.0
    private let targetChannels: AVAudioChannelCount = 1
    private let bufferQueue = DispatchQueue(label: "com.voicetype.audiocapture.buffer", qos: .userInitiated)

    private var audioBuffer: [Float] = []
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: DispatchSourceTimer?
    private var isRecording = false
    private let stateQueue = DispatchQueue(label: "com.voicetype.audiocapture.state", qos: .userInitiated)

    @Published public var audioLevel: Float = 0.0

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

    public func startRecording() throws {
        var currentlyRecording = false
        stateQueue.sync { currentlyRecording = isRecording }
        guard !currentlyRecording else {
            throw AudioCaptureError.alreadyRecording
        }

        stopMeterTimer()
        cleanupRecordingFile()
        bufferQueue.sync { audioBuffer.removeAll() }

        let recordingURL = makeRecordingURL()
        let recorder = try AVAudioRecorder(url: recordingURL, settings: recordingSettings())
        recorder.isMeteringEnabled = true

        guard recorder.prepareToRecord(), recorder.record() else {
            throw AudioCaptureError.recorderStartFailed
        }

        self.audioRecorder = recorder
        self.recordingURL = recordingURL
        stateQueue.sync { isRecording = true }

        DispatchQueue.main.async {
            self.audioLevel = 0
        }

        startMeterTimer(for: recorder)
        print("[AudioCapture] Recorder started at: \(recordingURL.lastPathComponent)")
    }

    public func stopRecording() throws -> [Float] {
        let (samples, _) = try stopRecordingCore(savingAudioTo: nil)
        return samples
    }

    /// Stop recording, return samples, and optionally copy the raw audio file
    /// to `saveURL` before it is deleted from the temp directory.
    /// Returns (samples, audioDurationSeconds). audioDurationSeconds is nil if
    /// the save failed or was not requested.
    public func stopRecordingRetaining(savingAudioTo saveURL: URL) throws -> ([Float], Double?) {
        return try stopRecordingCore(savingAudioTo: saveURL)
    }

    @discardableResult
    private func stopRecordingCore(savingAudioTo saveURL: URL?) throws -> ([Float], Double?) {
        var currentlyRecording = false
        stateQueue.sync { currentlyRecording = isRecording }
        guard currentlyRecording else {
            throw AudioCaptureError.notRecording
        }

        stopMeterTimer()

        guard let recorder = audioRecorder, let recordingURL else {
            stateQueue.sync { isRecording = false }
            throw AudioCaptureError.recordingFileMissing
        }

        recorder.stop()
        audioRecorder = nil
        self.recordingURL = nil
        stateQueue.sync { isRecording = false }
        audioLevel = 0

        let samples = try loadSamples(from: recordingURL)

        // Optionally persist a copy before deletion.
        var savedDuration: Double?
        if let destination = saveURL {
            do {
                try FileManager.default.copyItem(at: recordingURL, to: destination)
                // Compute duration from sample count at the known target rate.
                if !samples.isEmpty {
                    savedDuration = Double(samples.count) / targetSampleRate
                }
            } catch {
                // Non-fatal: eval audio save failure must not block transcription.
                print("[AudioCapture] Failed to save eval audio: \(error)")
            }
        }

        try? FileManager.default.removeItem(at: recordingURL)

        return (samples, savedDuration)
    }

    private func recordingSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: Int(targetChannels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceType-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private func cleanupRecordingFile() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func startMeterTimer(for recorder: AVAudioRecorder) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            let peakPower = recorder.peakPower(forChannel: 0)
            let avgLevel = self.normalizedDecibelLevel(averagePower)
            let peakLevel = self.normalizedDecibelLevel(peakPower)
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

    private func normalizedDecibelLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        if decibels <= -80 { return 0 }
        return pow(10, decibels / 20)
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
            frameCapacity: AVAudioFrameCount(convertedSamples.count)
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

public enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case formatCreationFailed
    case sessionConfigurationFailed(Error)
    case engineStartFailed(Error)
    case invalidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    case noInputBuffersReceived
    case recorderStartFailed
    case recordingFileMissing
    case recordingReadFailed(Error)
    case recordingConversionFailed

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
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .invalidInputFormat(let sampleRate, let channelCount):
            return "Audio input is unavailable for VoiceType right now (sampleRate=\(sampleRate), channels=\(channelCount)). Check the active input device in macOS and try again."
        case .noInputBuffersReceived:
            return "VoiceType started recording but macOS did not deliver any microphone buffers. Check the active input device and relaunch the app if the device was changed recently."
        case .recorderStartFailed:
            return "VoiceType could not start the microphone recorder. Check the active input device in macOS and try again."
        case .recordingFileMissing:
            return "VoiceType lost the temporary recording file before transcription could start."
        case .recordingReadFailed(let error):
            return "VoiceType could not read the recorded audio: \(error.localizedDescription)"
        case .recordingConversionFailed:
            return "VoiceType could not convert the recorded audio into the transcription format."
        }
    }
}
