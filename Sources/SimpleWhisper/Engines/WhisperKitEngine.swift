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
        status(isDownloaded ? "Loading \(kind.title)… (first load compiles the model)" : "Downloading \(kind.title)…")
        do {
            whisperKit = try await load()
        } catch {
            // An interrupted download leaves *.incomplete files that WhisperKit cannot resume from.
            // Wipe the partial model and try once more.
            DebugLog.write("WhisperKit load failed (\(error.localizedDescription)); clearing partial download and retrying")
            removePartialDownload()
            status("Retrying download of \(kind.title)…")
            whisperKit = try await load()
        }
        status("Model ready")
    }

    private func load() async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: kind.whisperVariant,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        return try await WhisperKit(config)
    }

    private static let modelsBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")

    private var modelFolder: URL? {
        kind.whisperVariant.map { Self.modelsBase.appendingPathComponent("openai_whisper-\($0)") }
    }

    /// True when the model files are already on disk (the decoder weights are the last thing written).
    var isDownloaded: Bool {
        guard let folder = modelFolder else { return false }
        let weights = folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        return FileManager.default.fileExists(atPath: weights.path)
    }

    private func removePartialDownload() {
        guard let folder = modelFolder else { return }
        for url in [folder, Self.modelsBase.appendingPathComponent(".cache/huggingface/download/\(folder.lastPathComponent)")] {
            try? FileManager.default.removeItem(at: url)
        }
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
            // Timestamps are required for recordings longer than one 30 s window: without them the
            // decoder cannot advance the window and everything after 30 s is dropped.
            withoutTimestamps: false,
            promptTokens: promptTokens,
            chunkingStrategy: .none
        )
        var results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        var text = Self.joinedText(results)
        if text.isEmpty, promptTokens != nil {
            // Some variants (large-v3 turbo) return nothing when a vocabulary prompt is supplied.
            var plain = options
            plain.promptTokens = nil
            results = try await kit.transcribe(audioArray: samples, decodeOptions: plain)
            text = Self.joinedText(results)
            debugInfo = (debugInfo ?? "") + " (retried without vocabulary prompt)"
        }
        let detected = languageCode ?? results.first?.language
        return Transcription(text: text, detectedLanguage: detected, debugInfo: debugInfo)
    }

    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
