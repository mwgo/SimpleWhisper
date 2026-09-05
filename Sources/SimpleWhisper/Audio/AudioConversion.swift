import Foundation
import AVFoundation

enum AudioConversion {
    /// Wraps 16 kHz mono samples in a PCM buffer converted to `format`.
    static func buffer(from samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AudioRecorder.targetFormat
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EngineError.audioConversionFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            sourceBuffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        if format.sampleRate == source.sampleRate,
           format.channelCount == source.channelCount,
           format.commonFormat == source.commonFormat,
           format.isInterleaved == source.isInterleaved {
            return sourceBuffer
        }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw EngineError.audioConversionFailed }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw EngineError.audioConversionFailed
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error else { throw error ?? EngineError.audioConversionFailed }
        return output
    }
}
