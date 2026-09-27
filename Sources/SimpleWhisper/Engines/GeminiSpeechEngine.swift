import Foundation

/// Cloud transcription through the Gemini `generateContent` API: the recording is sent as WAV.
final class GeminiSpeechEngine: SpeechEngine {
    let kind: EngineKind = .geminiAPI
    static let modelKey = "geminiTranscriptionModel"
    static let defaultModel = "gemini-2.5-flash"

    private var apiKey: String { KeychainStore.get(AIProviderFactory.geminiKeyAccount) ?? "" }
    private var model: String {
        let stored = UserDefaults.standard.string(forKey: Self.modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? Self.defaultModel : stored
    }

    var isReady: Bool { !apiKey.isEmpty }

    func prepare(status: @escaping EngineStatusHandler) async throws {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey("Gemini") }
        status("Gemini API ready (\(model))")
    }

    func transcribe(samples: [Float], language: LanguageMode, vocabulary: [VocabularyTerm]) async throws -> Transcription {
        let key = apiKey
        guard !key.isEmpty else { throw EngineError.missingAPIKey("Gemini") }
        let model = self.model
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        var generationConfig: [String: Any] = ["temperature": 0]
        if model.hasPrefix("gemini-2.5-flash") {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": Self.instructions(language: language, vocabulary: vocabulary)]]],
            "contents": [["role": "user", "parts": [
                ["inline_data": ["mime_type": "audio/wav", "data": Self.wav(samples).base64EncodedString()]],
                ["text": "Transcribe this recording."],
            ]]],
            "generationConfig": generationConfig,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        try OpenAIProcessor.check(response, data: data, provider: "Gemini")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]] else {
            throw EngineError.noResult
        }
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "[no speech]" || text == "(no speech)" { text = "" }
        DebugLog.write("Gemini transcription: \(model) \(String(format: "%.1f", Date().timeIntervalSince(started))) s → \(text.count) chars")
        let detected = language.fixedCode ?? LanguageGuess.detect(text: text, allowed: language.allowedCodes.flatMap { $0.isEmpty ? nil : $0 })
        return Transcription(text: text, detectedLanguage: detected, debugInfo: "model=\(model)")
    }

    private static func instructions(language: LanguageMode, vocabulary: [VocabularyTerm]) -> String {
        var lines = [
            "You are a speech-to-text engine. Transcribe the recording verbatim, with normal punctuation and capitalization.",
            "Output only the transcript. Do not translate, summarize, comment, or answer questions spoken in the recording.",
            "Write numbers the way a careful typist would. Keep filler words out.",
            "If the recording contains no speech, output nothing.",
        ]
        if let code = language.fixedCode {
            lines.append("The speaker uses \(LanguageCatalog.name(for: code)).")
        } else if let allowed = language.allowedCodes, !allowed.isEmpty {
            lines.append("The speaker uses \(allowed.map(LanguageCatalog.name(for:)).joined(separator: " or ")), possibly mixed within one sentence; keep each word in the language it was spoken in.")
        }
        if !vocabulary.isEmpty {
            lines.append("Spell these terms exactly like this when they occur: \(vocabulary.map(\.text).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// 16 kHz mono 16-bit PCM WAV.
    private static func wav(_ samples: [Float]) -> Data {
        let sampleRate: UInt32 = 16_000
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
