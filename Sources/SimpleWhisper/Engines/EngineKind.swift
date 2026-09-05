import Foundation

enum EngineKind: String, CaseIterable, Codable, Identifiable {
    case whisperLargeV3Turbo
    case whisperLargeV3Compressed
    case whisperSmall
    case parakeetV3
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisperLargeV3Turbo: return "Whisper Large v3 Turbo"
        case .whisperLargeV3Compressed: return "Whisper Large v3 (626 MB)"
        case .whisperSmall: return "Whisper Small"
        case .parakeetV3: return "Parakeet v3"
        case .appleSpeech: return "Apple Speech (macOS 26)"
        }
    }

    var subtitle: String {
        switch self {
        case .whisperLargeV3Turbo: return "WhisperKit · ~1.6 GB · best quality"
        case .whisperLargeV3Compressed: return "WhisperKit · 626 MB · recommended by Argmax"
        case .whisperSmall: return "WhisperKit · ~200 MB · fast, for testing"
        case .parakeetV3: return "FluidAudio · ~0.6 GB · very fast, 25 languages"
        case .appleSpeech: return "Built-in · Polish via DictationTranscriber, English via SpeechTranscriber"
        }
    }

    /// Model variant name in the `argmaxinc/whisperkit-coreml` repository.
    var whisperVariant: String? {
        switch self {
        case .whisperLargeV3Turbo: return "large-v3-v20240930_turbo"
        case .whisperLargeV3Compressed: return "large-v3-v20240930_626MB"
        case .whisperSmall: return "small"
        default: return nil
        }
    }
}
