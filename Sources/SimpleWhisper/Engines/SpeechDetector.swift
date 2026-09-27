import Foundation
import FluidAudio

/// Silero VAD (via FluidAudio): tells speech from silence and noise, which a loudness threshold cannot.
/// Loaded lazily on first use; if the model cannot be loaded the filters are skipped.
actor SpeechDetector {
    static let shared = SpeechDetector()
    static let sampleRate = 16_000
    /// VAD probability per 256 ms window.
    static let window = VadManager.chunkSize

    private var manager: VadManager?
    private var loadFailed = false

    private func vad() async -> VadManager? {
        if let manager { return manager }
        guard !loadFailed else { return nil }
        do {
            let loaded = try await VadManager()
            manager = loaded
            return loaded
        } catch {
            loadFailed = true
            DebugLog.write("VAD unavailable, silence filter skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Speech regions (sample ranges), neighbours closer than `mergeGap` seconds joined. nil = VAD unavailable.
    func speechRegions(_ samples: [Float], mergeGap: Double = 1.0) async -> [Range<Int>]? {
        guard let vad = await vad() else { return nil }
        let config = VadSegmentationConfig(maxSpeechDuration: 600, speechPadding: 0.25)
        guard let segments = try? await vad.segmentSpeech(samples, config: config) else { return nil }
        var regions: [Range<Int>] = []
        for segment in segments {
            let range = max(0, segment.startSample(sampleRate: Self.sampleRate))..<min(samples.count, segment.endSample(sampleRate: Self.sampleRate))
            guard !range.isEmpty else { continue }
            if let last = regions.last, Double(range.lowerBound - last.upperBound) < mergeGap * Double(Self.sampleRate) {
                regions[regions.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                regions.append(range)
            }
        }
        return regions
    }

    /// Keeps only the speech: leading/trailing silence and long pauses are cut out, the remaining
    /// pieces are joined with a short gap. Returns `[]` when there is no speech at all, and the input
    /// unchanged when the VAD is unavailable.
    func keepSpeech(_ samples: [Float]) async -> [Float] {
        guard let regions = await speechRegions(samples) else { return samples }
        guard !regions.isEmpty else { return [] }
        let gap = [Float](repeating: 0, count: Self.sampleRate / 4)
        var result: [Float] = []
        result.reserveCapacity(samples.count)
        for (index, region) in regions.enumerated() {
            if index > 0 { result += gap }
            result += samples[region]
        }
        return result
    }

    /// Speech probability for every 256 ms window of `samples`. nil = VAD unavailable.
    func probabilities(_ samples: [Float]) async -> [Float]? {
        guard let vad = await vad(), let results = try? await vad.process(samples), !results.isEmpty else { return nil }
        return results.map(\.probability)
    }

    /// Median of `probabilities` over a time span in seconds (robust to one window of trailing speech).
    static func median(_ probabilities: [Float], from start: Double, to end: Double) -> Float? {
        let windowSeconds = Double(window) / Double(sampleRate)
        let first = max(0, Int(start / windowSeconds))
        let last = min(probabilities.count - 1, max(first, Int(ceil(end / windowSeconds)) - 1))
        guard !probabilities.isEmpty, first <= last else { return nil }
        let slice = probabilities[first...last].sorted()
        return slice[slice.count / 2]
    }
}
