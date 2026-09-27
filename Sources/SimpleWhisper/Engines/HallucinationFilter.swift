import Foundation

/// Removes text Whisper-style models invent on silence or noise ("Dziękuję.", "Thank you.",
/// "Napisy stworzone przez społeczność Amara.org"…).
enum HallucinationFilter {
    /// Never real dictation: removed wherever they appear.
    static let credits = [
        "amara.org", "napisy stworzone przez", "napisy wykonane przez", "napisy przygotowane przez",
        "thanks for watching", "thank you for watching", "dzięki za obejrzenie", "dziękuję za obejrzenie",
        "subtitles by", "zapraszam do subskrypcji", "like and subscribe", "transcribed by",
    ]
    /// Could be real speech: removed only when the audio under them is not speech according to the VAD.
    static let ambiguous: Set<String> = [
        "dziękuję", "dziękuję bardzo", "dziękuję za uwagę", "dzięki", "tak", "okej",
        "thank you", "thank you very much", "thanks", "you", "bye", "okay",
    ]
    static let speechThreshold: Float = 0.35

    static func clean(_ transcription: Transcription, samples: [Float]) async -> String {
        let duration = Double(samples.count) / Double(SpeechDetector.sampleRate)
        let pieces = transcription.segments.isEmpty
            ? [TimedText(start: 0, end: duration, text: transcription.text)]
            : transcription.segments
        let sentences = pieces.flatMap(split)
        var probabilities: [Float]?? = nil   // computed at most once, only when needed
        var kept: [String] = []
        var removed: [String] = []
        for sentence in sentences {
            let key = normalize(sentence.text)
            if key.isEmpty { continue }
            if credits.contains(where: { key.contains($0) }) {
                removed.append(sentence.text)
                continue
            }
            if ambiguous.contains(key) {
                if probabilities == nil { probabilities = .some(await SpeechDetector.shared.probabilities(samples)) }
                if let probs = probabilities ?? nil,
                   let speech = SpeechDetector.median(probs, from: sentence.start, to: sentence.end), speech < speechThreshold {
                    removed.append(String(format: "%@ (speech %.2f)", sentence.text, speech))
                    continue
                }
            }
            kept.append(sentence.text)
        }
        guard !removed.isEmpty else { return transcription.text }
        DebugLog.write("Hallucination filter removed: \(removed.joined(separator: " | "))")
        return kept.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a timed piece into sentences, spreading its time span by character count.
    private static func split(_ piece: TimedText) -> [TimedText] {
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?…".contains(character) {
                parts.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        let total = Double(max(text.count, 1))
        var offset = 0
        return parts.map { part in
            let start = piece.start + (piece.end - piece.start) * Double(offset) / total
            offset += part.count
            let end = piece.start + (piece.end - piece.start) * Double(offset) / total
            return TimedText(start: start, end: end, text: part.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
