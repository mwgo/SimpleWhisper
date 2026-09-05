import Foundation
import WhisperKit

final class WhisperKitEngine: SpeechEngine {
    let kind: EngineKind
    private var whisperKit: WhisperKit?

    init(kind: EngineKind) {
        self.kind = kind
    }

    var isReady: Bool { whisperKit != nil }

    func prepare(status: @escaping EngineStatusHandler) async throws {
        if whisperKit != nil { return }
        status("Downloading \(kind.title)…")
        let config = WhisperKitConfig(
            model: kind.whisperVariant,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        whisperKit = kit
        status("Model ready")
    }

    func transcribe(samples: [Float], language: LanguageMode, vocabulary: [VocabularyTerm]) async throws -> Transcription {
        guard let kit = whisperKit else { throw EngineError.notPrepared }

        var languageCode = language.fixedCode
        var debugInfo: String? = nil
        if languageCode == nil, let allowed = language.allowedCodes {
            let detection = try await kit.detectLangauge(audioArray: samples)
            let candidates = allowed.map { ($0, detection.langProbs[$0] ?? -Float.infinity) }
            languageCode = candidates.max { $0.1 < $1.1 }?.0
            let top = detection.langProbs.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
            debugInfo = "detected=\(detection.language) top: \(top)"
        }

        var promptTokens: [Int]? = nil
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let promptText = " " + vocabulary.map(\.text).joined(separator: ", ") + "."
            let tokens = tokenizer.encode(text: promptText).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = tokens.isEmpty ? nil : tokens
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = languageCode ?? results.first?.language
        return Transcription(text: text, detectedLanguage: detected, debugInfo: debugInfo)
    }
}
