import Foundation

/// Two-stage macro expansion so an AI post-processing step never sees (or rewrites) the inserted content.
enum MacroExpander {
    struct Stage1Result {
        var text: String
        var usedMacroIDs: Set<UUID> = []
        var clipboardWasEmpty = false
    }

    static func placeholder(for macro: VoiceMacro) -> String {
        "⟦MACRO:\(macro.id.uuidString)⟧"
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: "⟦MACRO:([0-9A-Fa-f-]+)⟧")
    /// Punctuation the speech model may have put right next to a spoken punctuation word.
    private static let neighbouringPunctuation = "[\\s,.;:!?]*"

    /// Replaces spoken keywords with opaque placeholders.
    static func stage1(_ text: String, macros: [VoiceMacro], clipboard: String?) -> Stage1Result {
        var result = Stage1Result(text: text)
        let clipboardEmpty = (clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Longer keywords first so "nawias otwarty" wins over a hypothetical "nawias".
        let ordered = macros.flatMap { macro in macro.keywords.map { (macro, $0.trimmingCharacters(in: .whitespaces)) } }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (macro, keyword) in ordered {
            guard WordMatcher.contains(word: keyword, in: result.text) else { continue }
            if macro.action == .insertClipboard && clipboardEmpty {
                result.clipboardWasEmpty = true
                continue
            }
            result.usedMacroIDs.insert(macro.id)
            let token = placeholder(for: macro)
            if macro.action == .punctuation {
                // Swallow punctuation/spaces the model already placed around the spoken word,
                // so "kota, przecinek, a nie" becomes a single comma later.
                let pattern = neighbouringPunctuation + WordMatcher.pattern(for: keyword) + neighbouringPunctuation
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(location: 0, length: (result.text as NSString).length)
                    result.text = regex.stringByReplacingMatches(in: result.text, range: range, withTemplate: " \(token) ")
                }
            } else {
                result.text = WordMatcher.replace(word: keyword, in: result.text) { _ in token }
            }
        }
        return result
    }

    /// Replaces placeholders with the actual content, applying spacing/capitalisation rules for punctuation.
    static func stage2(_ text: String, macros: [VoiceMacro], clipboard: String?) -> String {
        // Tidy the dictated text first so inserted content (e.g. indented code) is left untouched.
        var output = tidy(text)
        let byID = Dictionary(uniqueKeysWithValues: macros.map { ($0.id.uuidString.uppercased(), $0) })
        var quoteOpen = false
        var searchStart = 0

        while true {
            let nsOutput = output as NSString
            let searchRange = NSRange(location: searchStart, length: nsOutput.length - searchStart)
            guard let match = placeholderRegex.firstMatch(in: output, range: searchRange) else { break }
            let id = nsOutput.substring(with: match.range(at: 1)).uppercased()
            let before = nsOutput.substring(to: match.range.location)
            let after = nsOutput.substring(from: match.range.location + match.range.length)
            guard let macro = byID[id] else {
                // Unknown placeholder (macro deleted meanwhile): drop it.
                output = before + after
                searchStart = (before as NSString).length
                continue
            }
            let joined: String
            switch macro.action {
            case .punctuation:
                joined = applyPunctuation(macro.text, before: before, after: after, quoteOpen: &quoteOpen)
            case .insertClipboard:
                joined = join(before: before, content: formatClipboard(clipboard ?? ""), after: after)
            case .newLine:
                joined = trimTrailingSpaces(before) + "\n" + trimLeadingSpaces(after)
            case .insertText:
                joined = join(before: before, content: macro.text, after: after)
            }
            // Continue after the inserted content, never re-scanning it (clipboard text may contain anything).
            searchStart = (joined as NSString).length - (trimLeadingSpaces(after) as NSString).length
            searchStart = max(0, min(searchStart, (joined as NSString).length))
            output = joined
        }
        return output.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Joining rules

    private static let sentenceEnders: Set<String> = [".", "?", "!"]
    private static let clauseMarks: Set<String> = [",", ";", ":"]

    private static func applyPunctuation(_ symbol: String, before rawBefore: String, after rawAfter: String, quoteOpen: inout Bool) -> String {
        var before = trimTrailingSpaces(rawBefore)
        var after = trimLeadingSpaces(rawAfter)

        if symbol == VoiceMacro.paragraphMark {
            before = before.trimmingCharacters(in: .whitespacesAndNewlines)
            return (before.isEmpty ? "" : before + "\n\n") + capitalizeFirst(after)
        }
        if sentenceEnders.contains(symbol) || clauseMarks.contains(symbol) {
            // Replace a mark the model already put there instead of doubling it.
            while let last = before.last, ",.;:!?".contains(last) { before.removeLast() }
            before = trimTrailingSpaces(before)
            if before.isEmpty { return after }   // nothing to punctuate yet
            var rest = after
            if let next = rest.first, ",.;:!?".contains(next) {
                // Two marks collide (e.g. the AI dropped the word between them): keep the stronger one.
                if clauseMarks.contains(symbol) { return before + spaceBefore(rest) }
                while let first = rest.first, ",.;:!?".contains(first) { rest.removeFirst() }
                rest = trimLeadingSpaces(rest)
            }
            if sentenceEnders.contains(symbol) { rest = capitalizeFirst(rest) }
            return before + symbol + spaceBefore(rest)
        }
        switch symbol {
        case "–", "-", "—":
            return (before.isEmpty ? "" : before + " ") + symbol + spaceBefore(after)
        case "(", "[", "{":
            return (before.isEmpty ? "" : before + " ") + symbol + after
        case ")", "]", "}":
            return before + symbol + spaceBefore(after)
        case "\"":
            quoteOpen.toggle()
            return quoteOpen
                ? (before.isEmpty ? "" : before + " ") + symbol + after
                : before + symbol + spaceBefore(after)
        default:
            return join(before: before, content: symbol, after: after)
        }
    }

    private static func join(before: String, content: String, after: String) -> String {
        let left = trimTrailingSpaces(before)
        var right = trimLeadingSpaces(after)
        if content.hasSuffix("\n") {
            // A mark the model glued to the keyword ("schowek.i") would dangle at the start of a line.
            while let first = right.first, ",.;:!?".contains(first) { right.removeFirst() }
            right = trimLeadingSpaces(right)
        }
        var result = left
        if !left.isEmpty && !content.hasPrefix("\n") { result += " " }
        result += content
        if !right.isEmpty && !content.hasSuffix("\n") { result += " " }
        return result + right
    }

    /// A single space, unless the continuation is empty, starts on a new line, or with a closing mark.
    private static func spaceBefore(_ rest: String) -> String {
        guard let first = rest.first else { return "" }
        if first == "\n" || ")]}\"".contains(first) || ",.;:!?".contains(first) { return rest }
        return " " + rest
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func trimTrailingSpaces(_ text: String) -> String {
        var s = Substring(text)
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return String(s)
    }

    private static func trimLeadingSpaces(_ text: String) -> String {
        var s = Substring(text)
        while let first = s.first, first == " " || first == "\t" { s.removeFirst() }
        return String(s)
    }

    private static func formatClipboard(_ raw: String) -> String {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.contains("\n") {
            return "\n" + content + "\n"
        }
        return content
    }

    /// Normalises spacing around punctuation in the dictated text.
    private static func tidy(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: " \n", with: "\n")
        output = output.replacingOccurrences(of: "\n ", with: "\n")
        while output.contains("  ") { output = output.replacingOccurrences(of: "  ", with: " ") }
        output = output.replacingOccurrences(of: " ,", with: ",")
        output = output.replacingOccurrences(of: " .", with: ".")
        return output.trimmingCharacters(in: .whitespaces)
    }
}
