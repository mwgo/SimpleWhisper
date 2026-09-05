import Foundation
import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device is available."
        case .converterUnavailable: return "Could not create an audio converter."
        }
    }
}

/// Captures the default microphone and accumulates 16 kHz mono Float32 samples.
final class AudioRecorder {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    /// Called on the audio thread with a smoothed input level in 0…1.
    var onLevel: ((Double) -> Void)?
    private var smoothedLevel: Double = 0

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capturing and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        return lock.withLock {
            let captured = samples
            samples = []
            return captured
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return }
        let converted = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        lock.withLock { samples.append(contentsOf: converted) }
        reportLevel(converted)
    }

    private func reportLevel(_ chunk: [Float]) {
        guard let onLevel, !chunk.isEmpty else { return }
        let rms = sqrt(chunk.reduce(0) { $0 + Double($1 * $1) } / Double(chunk.count))
        let decibels = 20 * log10(max(rms, 1e-7))
        // Typical speech sits around -35…-10 dBFS; map that range onto 0…1.
        let normalized = min(max((decibels + 45) / 35, 0), 1)
        smoothedLevel = normalized > smoothedLevel ? normalized : smoothedLevel * 0.6 + normalized * 0.4
        onLevel(smoothedLevel)
    }
}
