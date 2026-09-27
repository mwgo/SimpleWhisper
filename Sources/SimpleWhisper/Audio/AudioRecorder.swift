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
    /// Pause detection for live typing; segments are queued under `lock` and taken on the main thread.
    var segmentsEnabled = false
    private var segmenter = PauseSegmenter()
    private var readySegments: [Range<Int>] = []
    /// Called on the audio thread when `takeSegments()` has something new.
    var onSegmentsAvailable: (() -> Void)?

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            segmenter.reset()
            readySegments = []
        }
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
        let hasSegments: Bool = lock.withLock {
            samples.append(contentsOf: converted)
            guard segmentsEnabled else { return false }
            let found = segmenter.feed(converted)
            readySegments.append(contentsOf: found)
            return !found.isEmpty
        }
        if hasSegments { onSegmentsAvailable?() }
        reportLevel(converted)
    }

    /// Finished speech segments since the last call, in recording order.
    func takeSegments() -> [Range<Int>] {
        lock.withLock {
            defer { readySegments = [] }
            return readySegments
        }
    }

    /// The open (not yet committed) segment: from its start to the newest sample, and whether it has speech.
    func openSegment() -> (range: Range<Int>, hasSpeech: Bool) {
        lock.withLock { (segmenter.segmentStart..<max(samples.count, segmenter.segmentStart), segmenter.hasSpeech) }
    }

    func samples(in range: Range<Int>) -> [Float] {
        lock.withLock {
            let clamped = range.clamped(to: 0..<samples.count)
            return Array(samples[clamped])
        }
    }

    /// Stops like `stop()` and also returns segments not yet taken plus the unfinished tail.
    func stopWithSegments() -> (samples: [Float], segments: [Range<Int>]) {
        let segments = takeSegments()
        let all = stop()
        var tail: Range<Int>? = nil
        lock.withLock { tail = segmenter.finish(total: all.count) }
        return (all, segments + (tail.map { [$0] } ?? []))
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
