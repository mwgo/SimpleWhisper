import AVFoundation

/// Very short synthesized cues: a rising sweep when recording starts, a falling one when it stops.
@MainActor
enum SoundPlayer {
    private static let startPlayer = makePlayer(from: 440, to: 660)
    private static let stopPlayer = makePlayer(from: 660, to: 400)
    /// Cancel: a lower, duller drop.
    private static let cancelPlayer = makePlayer(from: 360, to: 220)

    static func recordingStarted() { play(startPlayer) }
    static func recordingStopped() { play(stopPlayer) }
    static func recordingCancelled() { play(cancelPlayer) }

    private static func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    /// 45 ms gentle sine sweep with a raised-cosine (Hann) envelope, rendered to an in-memory WAV.
    private static func makePlayer(from startHz: Double, to endHz: Double) -> AVAudioPlayer? {
        let sampleRate = 44_100.0
        let duration = 0.045
        let frames = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: frames)
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / Double(frames)
            let frequency = startHz + (endHz - startHz) * t
            phase += 2 * .pi * frequency / sampleRate
            let envelope = 0.5 - 0.5 * cos(2 * .pi * t)   // Hann window: no clicks, very soft edges
            samples[i] = Int16(max(-1, min(1, sin(phase) * envelope * 0.22)) * Double(Int16.max))
        }
        let player = try? AVAudioPlayer(data: wavData(samples: samples, sampleRate: Int(sampleRate)))
        player?.volume = 0.5
        player?.prepareToPlay()
        return player
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
