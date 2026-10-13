import Foundation

/// A word or short phrase said twice in a row ("na tym, na tym, że") is written once: the speaker restarted,
/// and the speech models keep both. Repeats across a full stop ("Tak. Tak.") stay.
enum RepetitionFilter {
    private static let maxWords = 4

    static func clean(_ text: String) -> String {
        var result = text
        while let range = firstRepeat(in: result) {
            result.removeSubrange(range)
        }
        return result
    }

    /// The second occurrence of the first repeat, with the separator before it.
    private static func firstRepeat(in text: String) -> Range<String.Index>? {
        let words = words(in: text)
        for start in words.indices {
            for count in stride(from: min(maxWords, (words.count - start) / 2), through: 1, by: -1) {
                let first = words[start..<start + count], second = words[start + count..<start + 2 * count]
                guard zip(first, second).allSatisfy({ $0.text.lowercased() == $1.text.lowercased() }) else { continue }
                let gap = text[first.last!.range.upperBound..<second.first!.range.lowerBound]
                guard gap.allSatisfy({ $0 == " " || $0 == "," || $0 == "-" || $0 == "–" || $0 == "—" }) else { continue }
                return first.last!.range.upperBound..<second.last!.range.upperBound
            }
        }
        return nil
    }

    private static func words(in text: String) -> [(text: Substring, range: Range<String.Index>)] {
        var result: [(text: Substring, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber { index = text.index(after: index) }
            result.append((text[start..<index], start..<index))
        }
        return result
    }
}
