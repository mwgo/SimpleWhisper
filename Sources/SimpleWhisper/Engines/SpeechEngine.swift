import Foundation
import NaturalLanguage

struct Transcription {
    var text: String
    var detectedLanguage: String?
    /// Engine-specific diagnostics (e.g. language probabilities), for the CLI test mode.
    var debugInfo: String? = nil
}

enum EngineError: LocalizedError {
    case notPrepared
    case noResult
    case localeUnsupported(String)
    case noAudioFormat
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "Speech model is not loaded."
        case .noResult: return "The speech model returned no text."
        case .localeUnsupported(let id): return "Locale \(id) is not supported by Apple Speech."
        case .noAudioFormat: return "Apple Speech did not provide an audio format."
        case .audioConversionFailed: return "Audio conversion failed."
        }
    }
}

typealias EngineStatusHandler = @Sendable (String) -> Void

protocol SpeechEngine: AnyObject {
    var kind: EngineKind { get }
    var isReady: Bool { get }
    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    func prepare(status: @escaping EngineStatusHandler) async throws
    func transcribe(samples: [Float], language: LanguageMode, vocabulary: [VocabularyTerm]) async throws -> Transcription
}

enum EngineFactory {
    static func make(_ kind: EngineKind) -> SpeechEngine {
        switch kind {
        case .whisperLargeV3Turbo, .whisperLargeV3Compressed, .whisperSmall:
            return WhisperKitEngine(kind: kind)
        case .parakeetV3:
            return ParakeetEngine()
        case .appleSpeech:
            return AppleSpeechEngine()
        }
    }
}

/// Text-based language guess used where the engine does not report a language itself.
enum LanguageGuess {
    static func detect(text: String, allowed: [String]?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        if let allowed {
            recognizer.languageConstraints = allowed.map { NLLanguage(rawValue: $0) }
        }
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue
    }
}
