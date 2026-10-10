import Foundation
import FluidAudio

final class ParakeetEngine: SpeechEngine {
    let kind: EngineKind
    private var manager: AsrManager?
    private var ctcModels: CtcModels?
    private var boosting: VocabularyBoostingSession?
    private var boostedTerms: [VocabularyTerm] = []

    var isReady: Bool { manager != nil }

    init(kind: EngineKind) {
        self.kind = kind
    }

    private var version: AsrModelVersion {
        kind == .parakeetUltra ? .ultra : .v3
    }

    func prepare(status: @escaping EngineStatusHandler) async throws {
        if manager != nil { return }
        status("Downloading \(kind.title)…")
        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        status("Model ready")
    }

    func transcribe(samples: [Float], language: LanguageMode, vocabulary: [VocabularyTerm]) async throws -> Transcription {
        guard let manager else { throw EngineError.notPrepared }
        let layers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: Self.scriptFilter(for: language))
        // The script filter can leave unknown-token markers where only another script would fit.
        var text = result.text.replacingOccurrences(of: "<unk>", with: "")
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        var debugInfo: String? = nil

        let boosted = vocabulary.filter { !$0.isMacroKeyword }
        if !boosted.isEmpty {
            do {
                let session = try await ensureBoosting(boosted)
                if let output = await session.rescore(text: text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples) {
                    let replacements = output.replacements.compactMap { item in
                        item.shouldReplace ? item.replacementWord.map { BoostReplacements.Replacement(original: item.originalWord, replacement: $0) } : nil
                    }
                    debugInfo = "vocabulary boosting: " + replacements.map { "[\($0.original) → \($0.replacement)]" }.joined(separator: " ")
                    text = BoostReplacements.apply(replacements, to: text, terms: boosted)
                } else {
                    debugInfo = "vocabulary boosting: no output (timings=\(result.tokenTimings?.count ?? 0))"
                }
            } catch {
                // Vocabulary boosting is optional; fall back to plain transcription.
                debugInfo = "vocabulary boosting failed: \(error.localizedDescription)"
            }
        }

        let detected = language.fixedCode ?? LanguageGuess.detect(text: text, allowed: language.allowedCodes)
        return Transcription(text: text.trimmingCharacters(in: .whitespacesAndNewlines), detectedLanguage: detected, debugInfo: debugInfo)
    }

    /// FluidAudio keeps the decoder to one writing script (no Cyrillic "крупко" for "kropka"); any allowed language
    /// stands for its script. No filter when the allowed languages use different or unknown scripts.
    private static func scriptFilter(for language: LanguageMode) -> Language? {
        let codes = language.allowedCodes ?? []
        let languages = codes.compactMap(Language.init(rawValue:))
        guard !languages.isEmpty, languages.count == codes.count, Set(languages.map(\.script)).count == 1 else { return nil }
        return languages.first
    }

    private func ensureBoosting(_ vocabulary: [VocabularyTerm]) async throws -> VocabularyBoostingSession {
        if let boosting, boostedTerms == vocabulary { return boosting }
        let ctc: CtcModels
        if let ctcModels {
            ctc = ctcModels
        } else {
            ctc = try await CtcModels.downloadAndLoad()
            ctcModels = ctc
        }
        let terms = vocabulary.map { term in
            CustomVocabularyTerm(text: term.text, aliases: term.aliases.isEmpty ? nil : term.aliases)
        }
        // The default 0.52 lets common words through ("nową" → "enova").
        let context = CustomVocabularyContext(terms: terms, minSimilarity: 0.65)
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
        boosting = session
        boostedTerms = vocabulary
        return session
    }
}
