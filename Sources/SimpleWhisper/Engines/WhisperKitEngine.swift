import Foundation
import WhisperKit

final class WhisperKitEngine: SpeechEngine {
    let kind: EngineKind
    private var whisperKit: WhisperKit?

    init(kind: EngineKind) {
        self.kind = kind
    }

    var isReady: Bool { whisperKit != nil }

    /// Whisper decodes 30 s windows; the vocabulary prompt is only used when the whole recording fits one.
    private static let singleWindowSeconds = 30.0
    /// Cleared the first time the prompt produces an empty/truncated result for this model.
    private var promptSupported = true

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

        let seconds = Double(samples.count) / 16_000
        // The vocabulary prompt is only reliable within a single 30 s window: with several windows
        // WhisperKit drops whole segments (Small) or returns nothing at all (Turbo, Large v3).
        var promptTokens: [Int]? = nil
        if !vocabulary.isEmpty, promptSupported, seconds <= Self.singleWindowSeconds, let tokenizer = kit.tokenizer {
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
        DebugLog.write("Whisper pass 1: \(String(format: "%.1f", seconds)) s → \(text.count) chars, \(results.flatMap(\.segments).count) segments, prompt=\(promptTokens?.count ?? 0) tokens")
        if promptTokens != nil, Self.looksTruncated(text, seconds: seconds) {
            // Some variants (large-v3 turbo/compressed) return nothing – or only a fragment of a long
            // recording – when a vocabulary prompt is supplied. Retry without it and keep the longer text.
            var plain = options
            plain.promptTokens = nil
            let retried = try await kit.transcribe(audioArray: samples, decodeOptions: plain)
            let retriedText = Self.joinedText(retried)
            DebugLog.write("Whisper pass 2 (no prompt): \(retriedText.count) chars, \(retried.flatMap(\.segments).count) segments")
            if retriedText.count > text.count {
                results = retried
                text = retriedText
                debugInfo = (debugInfo ?? "") + " (retried without vocabulary prompt)"
                // This model cannot cope with the prompt; stop paying for the first pass.
                promptSupported = false
                DebugLog.write("Vocabulary prompt disabled for \(kind.title)")
            }
        }
        let detected = languageCode ?? results.first?.language
        return Transcription(text: text, detectedLanguage: detected, debugInfo: debugInfo)
    }

    /// Empty output, or fewer than ~3 characters per second on a recording longer than 10 s,
    /// almost certainly means the decoder dropped whole windows.
    private static func looksTruncated(_ text: String, seconds: Double) -> Bool {
        if text.isEmpty { return true }
        return seconds > 10 && Double(text.count) / seconds < 3
    }

    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
