import AVFoundation
import Foundation
import Combine

public final class AudioCaptureService: ObservableObject {

    private let targetSampleRate: Double = 16000.0
    private let targetChannels: AVAudioChannelCount = 1

    private let audioEngine = AVAudioEngine()
    private let bufferQueue = DispatchQueue(label: "com.voicetype.audiocapture.buffer", qos: .userInitiated)

    private var audioBuffer: [Float] = []
    private var audioConverter: AVAudioConverter?
    private var isRecording = false
    private let stateQueue = DispatchQueue(label: "com.voicetype.audiocapture.state", qos: .userInitiated)

    @Published public var audioLevel: Float = 0.0

    public func startRecording() throws {
        var currentlyRecording = false
        stateQueue.sync { currentlyRecording = isRecording }
        guard !currentlyRecording else {
            throw AudioCaptureError.alreadyRecording
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Clear buffer on the queue to avoid race with pending async appends
        bufferQueue.sync { audioBuffer.removeAll() }
        audioConverter = createConverter(from: inputFormat)

        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )

        guard let recordingFormat else {
            throw AudioCaptureError.formatCreationFailed
        }

        let recordingBufferSize = AVAudioFrameCount(targetSampleRate) * 2
        let recordingBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: recordingBufferSize)!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate audio level for waveform visualization
            if let channelData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                var peak: Float = 0
                for i in 0..<frameCount {
                    let absVal = abs(channelData[0][i])
                    sum += absVal
                    if absVal > peak { peak = absVal }
                }
                let avgLevel = frameCount > 0 ? sum / Float(frameCount) : 0
                // Use peak detection with high sensitivity for better waveform response
                let level = max(avgLevel * 8, peak * 3)
                DispatchQueue.main.async {
                    self.audioLevel = min(level, 1.0)
                }
            }

            self.processBuffer(buffer, into: recordingBuffer)
        }

        do {
            try audioEngine.start()
        } catch {
            // Clean up the tap if the engine fails to start, preventing a dangling tap
            // that would block future startRecording calls
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }
        stateQueue.sync { isRecording = true }
        print("[AudioCapture] Engine started, tap installed. Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
    }

    public func stopRecording() throws -> [Float] {
        var currentlyRecording = false
        stateQueue.sync { currentlyRecording = isRecording }
        guard currentlyRecording else {
            throw AudioCaptureError.notRecording
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        stateQueue.sync { isRecording = false }
        audioLevel = 0

        var samples: [Float] = []
        bufferQueue.sync {
            samples = audioBuffer
            // Do NOT clear audioBuffer here — pending async append blocks from
            // the tap callback may still add samples. Clearing happens at the
            // start of the next startRecording() call.
        }

        return samples
    }

    private func createConverter(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )

        guard let outputFormat else {
            return nil
        }

        guard inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != targetChannels else {
            return nil
        }

        return AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    private func processBuffer(_ inputBuffer: AVAudioPCMBuffer, into outputBuffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else {
            appendBufferDirectly(inputBuffer)
            return
        }

        guard let inputCallbackBuffer = AVAudioPCMBuffer(
            pcmFormat: inputBuffer.format,
            frameCapacity: inputBuffer.frameCapacity
        ) else {
            appendBufferDirectly(inputBuffer)
            return
        }

        var inputAvailable = true
        var inputOffset: AVAudioFramePosition = 0
        let inputFrameCount = inputBuffer.frameLength

        outputBuffer.frameLength = 0

        while inputAvailable {
            let capacity = outputBuffer.frameCapacity - outputBuffer.frameLength

            guard capacity > 0 else {
                flushOutputBuffer(outputBuffer)
                outputBuffer.frameLength = 0
                continue
            }

            var error: NSError?

            let status = converter.convert(
                to: outputBuffer,
                error: &error
            ) { inNumberFrames, outStatus in
                outStatus.pointee = .haveData

                let framesToProvide = min(
                    AVAudioFrameCount(Int64(inputFrameCount) - inputOffset),
                    inNumberFrames
                )

                if let channelData = inputBuffer.floatChannelData {
                    for channel in 0..<Int(inputBuffer.format.channelCount) {
                        let src = channelData[channel].advanced(by: Int(inputOffset))
                        let dst = inputCallbackBuffer.floatChannelData![channel]
                        dst.update(from: src, count: Int(framesToProvide))
                    }
                }

                inputCallbackBuffer.frameLength = framesToProvide
                inputOffset += AVAudioFramePosition(framesToProvide)

                if inputOffset >= AVAudioFramePosition(inputFrameCount) {
                    inputAvailable = false
                    outStatus.pointee = .noDataNow
                }

                return inputCallbackBuffer
            }

            if status == .error {
                return
            }

            if outputBuffer.frameLength > 0 {
                extractSamples(from: outputBuffer)
                outputBuffer.frameLength = 0
            }
        }
    }

    private func appendBufferDirectly(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var samples: [Float]

        if channelCount == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            samples = Array(repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }

        bufferQueue.async {
            self.audioBuffer.append(contentsOf: samples)
        }
    }

    private func flushOutputBuffer(_ buffer: AVAudioPCMBuffer) {
        extractSamples(from: buffer)
    }

    private func extractSamples(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        bufferQueue.async {
            self.audioBuffer.append(contentsOf: samples)
        }
    }
}

public enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case formatCreationFailed
    case sessionConfigurationFailed(Error)
    case engineStartFailed(Error)

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
        }
    }
}
