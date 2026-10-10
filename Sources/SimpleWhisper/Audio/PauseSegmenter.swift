import Foundation

/// Splits a growing 16 kHz sample stream into speech segments at pauses.
/// Feed consecutive blocks with `feed`; each returned range is a finished segment (sample indices).
/// Segments are contiguous: audio is never thrown away, because quiet speech can sit below the threshold.
struct PauseSegmenter {
    var sampleRate: Double = 16_000
    /// A frame is silence when it is within this many dB of the noise floor.
    var silenceMarginDB: Double = 8
    var minSpeech: Double = 0.3
    var minPause: Double = 1.0
    /// Without a pause, cut anyway after this long (at the quietest recent moment); stays under Whisper's 30 s window.
    var maxSegment: Double = 25
    /// Louder bursts shorter than this (wind, a knock, echo) do not end a pause.
    var minBurst: Double = 0.15

    private let frameLength = 480   // 30 ms
    /// Noise floor = 10th percentile of the last ~9 s of frame levels.
    private let noiseWindow = 300
    private var pending: [Float] = []
    private var position = 0          // absolute index of the next unprocessed sample
    private(set) var segmentStart = 0
    /// True once the open segment contains speech (drives the live preview).
    var hasSpeech: Bool { speechSamples > 0 }
    private var speechSamples = 0
    private var silenceRun = 0
    private var burstRun = 0
    /// Energy of the last few frames (≈ 90 ms), smoothing out single loud frames inside pauses.
    private var recentEnergy: [Double] = []
    private var recentLevels: [Double] = []
    /// (end position, level) of the last 5 s, to place cuts at the quietest moment.
    private var recentFrames: [(position: Int, decibels: Double)] = []

    mutating func reset() {
        pending = []
        position = 0
        segmentStart = 0
        speechSamples = 0
        silenceRun = 0
        burstRun = 0
        recentEnergy = []
        recentLevels = []
        recentFrames = []
    }

    mutating func feed(_ block: [Float]) -> [Range<Int>] {
        pending.append(contentsOf: block)
        var segments: [Range<Int>] = []
        var offset = 0
        while pending.count - offset >= frameLength {
            let frame = pending[offset..<(offset + frameLength)]
            offset += frameLength
            if let segment = process(frame) { segments.append(segment) }
        }
        pending.removeFirst(offset)
        return segments
    }

    /// Closes the open segment now (the user moved the caret). Returns it if it contains speech.
    mutating func forceCut(total: Int) -> Range<Int>? {
        defer { segmentStart = max(segmentStart, total); speechSamples = 0; silenceRun = 0 }
        guard total > segmentStart, speechSamples > 0 else { return nil }
        return segmentStart..<total
    }

    /// The unfinished tail at the end of the recording, if it contains speech.
    mutating func finish(total: Int) -> Range<Int>? {
        defer { segmentStart = total; speechSamples = 0 }
        guard total > segmentStart, Double(speechSamples) / sampleRate >= 0.15 else { return nil }
        return segmentStart..<total
    }

    private mutating func process(_ frame: ArraySlice<Float>) -> Range<Int>? {
        let energy = frame.reduce(0) { $0 + Double($1 * $1) } / Double(frame.count)
        recentEnergy.append(energy)
        if recentEnergy.count > 3 { recentEnergy.removeFirst() }
        let decibels = 10 * log10(max(recentEnergy.reduce(0, +) / Double(recentEnergy.count), 1e-14))
        recentLevels.append(decibels)
        if recentLevels.count > noiseWindow { recentLevels.removeFirst() }
        let noiseFloor = recentLevels.sorted()[recentLevels.count / 10]
        position += frame.count
        recentFrames.append((position, decibels))
        if recentFrames.count > Int(5 * sampleRate) / frameLength { recentFrames.removeFirst() }

        if decibels > noiseFloor + silenceMarginDB {
            speechSamples += frame.count
            burstRun += frame.count
            if Double(burstRun) >= minBurst * sampleRate { silenceRun = 0 } else { silenceRun += frame.count }
        } else {
            burstRun = 0
            silenceRun += frame.count
        }

        if speechSamples == 0 {
            // A long stretch with no speech at all is trimmed to its last second.
            if Double(position - segmentStart) > 25 * sampleRate { segmentStart = position - Int(sampleRate) }
            return nil
        }
        if Double(silenceRun) >= minPause * sampleRate {
            defer { speechSamples = 0 }
            guard Double(speechSamples) >= minSpeech * sampleRate else { return nil }   // a click, not speech
            // Cut at the deepest point of the pause so the next segment never starts inside a word.
            return cut(after: position - silenceRun, upTo: position)
        }
        if Double(position - segmentStart) >= maxSegment * sampleRate {
            // Continuous speech: cut in the quietest gap of the last 3 s, not mid-word
            // (Whisper returns nothing for audio that starts inside a word).
            let segment = cut(after: position - Int(3 * sampleRate), upTo: position - Int(0.3 * sampleRate))
            speechSamples = max(position - segmentStart, 0)
            return segment
        }
        return nil
    }

    private mutating func cut(after lower: Int, upTo upper: Int) -> Range<Int> {
        let point = recentFrames.filter { $0.position > max(lower, segmentStart) && $0.position <= upper }
            .min { $0.decibels < $1.decibels }?.position ?? position
        let segment = segmentStart..<point
        segmentStart = point
        return segment
    }
}
