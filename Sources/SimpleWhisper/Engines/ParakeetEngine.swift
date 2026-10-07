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
        let forced = language.fixedCode.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: forced)
        var text = result.text
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
