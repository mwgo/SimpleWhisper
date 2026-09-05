import Foundation

/// Replaces known misrecognitions (aliases) with the canonical spelling, engine-independent.
enum VocabularyPostProcessor {
    static func apply(_ text: String, terms: [VocabularyTerm]) -> String {
        var output = text
        for term in terms {
            let canonical = term.text.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            for alias in term.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.lowercased() != canonical.lowercased() else { continue }
                output = WordMatcher.replace(word: trimmed, in: output) { _ in canonical }
            }
        }
        return output
    }
}

/// Case-insensitive whole-word matching that tolerates surrounding punctuation.
enum WordMatcher {
    static func pattern(for word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
            .replacingOccurrences(of: " ", with: "\\s+")
        return "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
    }

    static func replace(word: String, in text: String, with replacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern(for: word), options: [.caseInsensitive]) else {
            return text
        }
        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let matched = nsText.substring(with: match.range)
            let start = result.index(result.startIndex, offsetBy: 0)
            _ = start
            let nsResult = result as NSString
            result = nsResult.replacingCharacters(in: match.range, with: replacement(matched))
        }
        return result
    }

    static func contains(word: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern(for: word), options: [.caseInsensitive]) else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
