import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Built-in macOS 26 speech recognition. Uses the new `SpeechTranscriber` where the locale is
/// supported (e.g. English) and falls back to `DictationTranscriber` otherwise (e.g. Polish).
/// Each module is bound to one locale, so automatic language detection runs one pass per
/// candidate language and keeps the most confident result.
final class AppleSpeechEngine: SpeechEngine {
    let kind: EngineKind = .appleSpeech
    private(set) var isReady = false
    private let locales: [String: Locale] = [
        "pl": Locale(identifier: "pl-PL"),
        "en": Locale(identifier: "en-US"),
    ]

    private enum Module {
        case transcriber(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .transcriber(let module): return module
            case .dictation(let module): return module
            }
        }
    }

    func prepare(status: @escaping EngineStatusHandler) async throws {
        if isReady { return }
        for (code, locale) in locales {
            guard let module = try await makeModule(for: locale, withConfidence: false) else { continue }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.speechModule]) {
                status("Downloading Apple speech assets (\(code.uppercased()))…")
                try await request.downloadAndInstall()
            }
        }
        isReady = true
        status("Model ready")
    }

    func transcribe(samples: [Float], language: LanguageMode, vocabulary: [VocabularyTerm]) async throws -> Transcription {
        let codes = language.fixedCode.map { [$0] } ?? (language.allowedCodes ?? ["pl", "en"])
        var best: (code: String, text: String, score: Double)?
        var notes: [String] = []
        for code in codes {
            guard let locale = locales[code] else { continue }
            let pass = try await run(locale: locale, samples: samples)
            try Task.checkCancellation()
            let score = Self.score(text: pass.text, confidence: pass.confidence, language: code, allowed: codes)
            notes.append("\(code): conf=\(String(format: "%.2f", pass.confidence)) score=\(String(format: "%.2f", score)) [\(pass.module)]")
            if best == nil || score > best!.score {
                best = (code, pass.text, score)
            }
        }
        guard let best else { throw EngineError.noResult }
        return Transcription(text: best.text, detectedLanguage: best.code, debugInfo: notes.joined(separator: " "))
    }

    /// Ranks a pass: acoustic confidence (DictationTranscriber reports none, so assume a moderate
    /// value) weighted by how strongly the produced text reads as the pass's own language.
    private static func score(text: String, confidence: Double, language: String, allowed: [String]) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter }).count
        guard words > 0 else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = allowed.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        let probability = recognizer.languageHypotheses(withMaximum: allowed.count)[NLLanguage(rawValue: language)] ?? 0
        let effectiveConfidence = confidence > 0 ? confidence : 0.55
        return effectiveConfidence * probability
    }

    /// Picks the best available module for a locale, or nil if no Apple recognizer supports it.
    private func makeModule(for locale: Locale, withConfidence: Bool) async throws -> Module? {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let probe = SpeechTranscriber(locale: supported, preset: .transcription)
            if await AssetInventory.status(forModules: [probe]) != .unsupported {
                try await reserveIfNeeded(supported)
                let attributes: Set<SpeechTranscriber.ResultAttributeOption> = withConfidence ? [.transcriptionConfidence] : []
                return .transcriber(SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: attributes))
            }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let probe = DictationTranscriber(locale: supported, preset: .shortDictation)
            if await AssetInventory.status(forModules: [probe]) != .unsupported {
                try await reserveIfNeeded(supported)
                let attributes: Set<DictationTranscriber.ResultAttributeOption> = withConfidence ? [.transcriptionConfidence] : []
                return .dictation(DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: attributes))
            }
        }
        return nil
    }

    private func reserveIfNeeded(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }) {
            _ = try await AssetInventory.reserve(locale: locale)
        }
    }

    private func run(locale: Locale, samples: [Float]) async throws -> (text: String, confidence: Double, module: String) {
        guard let module = try await makeModule(for: locale, withConfidence: true) else {
            throw EngineError.localeUnsupported(locale.identifier)
        }
        switch module {
        case .transcriber(let transcriber):
            let result = try await analyze(module: transcriber, results: transcriber.results, samples: samples) { $0.text }
            return (result.text, result.confidence, "SpeechTranscriber")
        case .dictation(let transcriber):
            let result = try await analyze(module: transcriber, results: transcriber.results, samples: samples) { $0.text }
            return (result.text, result.confidence, "DictationTranscriber")
        }
    }

    private func analyze<Results: AsyncSequence & Sendable>(
        module: any SpeechModule,
        results: Results,
        samples: [Float],
        text: @escaping @Sendable (Results.Element) -> AttributedString
    ) async throws -> (text: String, confidence: Double) where Results.Element: SpeechModuleResult {
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw EngineError.noAudioFormat
        }
        let buffer = try AudioConversion.buffer(from: samples, to: format)
        if ProcessInfo.processInfo.environment["SW_DEBUG"] != nil {
            print("  [apple] format \(format.sampleRate) Hz ch=\(format.channelCount) \(format.commonFormat.rawValue) frames=\(buffer.frameLength)")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let collector = Task { () -> (String, Double) in
            var parts: [String] = []
            var confidences: [Double] = []
            for try await result in results where result.isFinal {
                let attributed = text(result)
                if ProcessInfo.processInfo.environment["SW_DEBUG"] != nil {
                    print("  [apple] result: \(String(attributed.characters).debugDescription)")
                }
                parts.append(String(attributed.characters))
                for run in attributed.runs {
                    if let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                        confidences.append(confidence)
                    }
                }
            }
            let average = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            return (parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), average)
        }

        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }
}
