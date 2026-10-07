import Foundation

/// Applies FluidAudio's vocabulary replacements to the original transcript more carefully than its own
/// output text: punctuation and neighbouring words caught in a replaced span are kept, the vocabulary
/// spelling is used, and replacements that merely re-spell an existing term or mismatch a word are skipped.
enum BoostReplacements {
    struct Replacement {
        var original: String
        var replacement: String
    }

    static func apply(_ replacements: [Replacement], to text: String, terms: [VocabularyTerm]) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let spellings = Dictionary(terms.map { ($0.text.lowercased(), $0.text) }, uniquingKeysWith: { first, _ in first })
        var cursor = 0
        for item in replacements {
            let span = item.original.split(separator: " ").map(String.init)
            guard !span.isEmpty, let start = find(span, in: tokens, from: cursor) ?? find(span, in: tokens, from: 0) else { continue }
            var range = start..<(start + span.count)
            let target = spellings[item.replacement.lowercased()] ?? item.replacement
            range = trimmed(range, tokens: tokens, target: target)
            let words = tokens[range].map(stripped)
            cursor = range.upperBound
            let spoken = words.joined(separator: " ")
            if let existing = spellings[spoken.lowercased()], existing != target || existing == spoken { continue }
            let targetWords = target.split(separator: " ").map(String.init)
            if words.count > 1, words.count == targetWords.count,
               zip(words, targetWords).contains(where: { similarity($0, $1) < 0.5 }) { continue }

            var word = target
            let atSentenceStart = range.lowerBound == 0 || tokens[range.lowerBound - 1].last.map { ".!?".contains($0) } == true
            if atSentenceStart, let first = word.first { word = first.uppercased() + word.dropFirst() }
            let leading = String(tokens[range.lowerBound].prefix { isEdgePunctuation($0) })
            let trailing = String(tokens[range.upperBound - 1].reversed().prefix { isEdgePunctuation($0) }.reversed())
            tokens.replaceSubrange(range, with: [leading + word + trailing])
            cursor = range.lowerBound + 1
        }
        return tokens.joined(separator: " ")
    }

    /// Drops edge words that only got caught in the span ("in Claude code," → "Claude code,").
    private static func trimmed(_ range: Range<Int>, tokens: [String], target: String) -> Range<Int> {
        var range = range
        func score(_ r: Range<Int>) -> Double { similarity(tokens[r].map(stripped).joined(), target) }
        while range.count > 1 {
            let full = score(range)
            let withoutFirst = (range.lowerBound + 1)..<range.upperBound
            let withoutLast = range.lowerBound..<(range.upperBound - 1)
            if score(withoutFirst) >= full, score(withoutFirst) >= score(withoutLast) {
                range = withoutFirst
            } else if score(withoutLast) >= full {
                range = withoutLast
            } else {
                break
            }
        }
        return range
    }

    private static func find(_ span: [String], in tokens: [String], from cursor: Int) -> Int? {
        guard tokens.count >= span.count, cursor <= tokens.count - span.count else { return nil }
        return (cursor...(tokens.count - span.count)).first { index in
            zip(tokens[index..<(index + span.count)], span).allSatisfy { stripped($0).lowercased() == stripped($1).lowercased() }
        }
    }

    private static func isEdgePunctuation(_ c: Character) -> Bool {
        c.isPunctuation && c != "'" && c != "-"
    }

    private static func stripped(_ word: String) -> String {
        var word = Substring(word)
        while let c = word.first, isEdgePunctuation(c) { word = word.dropFirst() }
        while let c = word.last, isEdgePunctuation(c) { word = word.dropLast() }
        return String(word)
    }

    /// 1 − Damerau-Levenshtein distance / longer length, on lowercase letters and digits.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in stride(from: 1, through: x.count, by: 1) {
            for j in stride(from: 1, through: y.count, by: 1) {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return 1 - Double(d[x.count][y.count]) / Double(longest)
    }
}
