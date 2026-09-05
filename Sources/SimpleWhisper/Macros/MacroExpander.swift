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

    /// Replaces spoken keywords with opaque placeholders.
    static func stage1(_ text: String, macros: [VoiceMacro], clipboard: String?) -> Stage1Result {
        var result = Stage1Result(text: text)
        let clipboardEmpty = (clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for macro in macros {
            for keyword in macro.keywords {
                let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, WordMatcher.contains(word: trimmed, in: result.text) else { continue }
                if macro.action == .insertClipboard && clipboardEmpty {
                    result.clipboardWasEmpty = true
                    continue
                }
                result.usedMacroIDs.insert(macro.id)
                result.text = WordMatcher.replace(word: trimmed, in: result.text) { _ in placeholder(for: macro) }
            }
        }
        return result
    }

    /// Replaces placeholders with the actual content.
    static func stage2(_ text: String, macros: [VoiceMacro], clipboard: String?) -> String {
        // Tidy the dictated text first so inserted content (e.g. indented code) is left untouched.
        var output = tidy(text)
        for macro in macros {
            let token = placeholder(for: macro)
            guard output.contains(token) else { continue }
            let replacement: String
            switch macro.action {
            case .insertClipboard:
                replacement = formatClipboard(clipboard ?? "")
            case .newLine:
                replacement = "\n"
            case .insertText:
                replacement = macro.text
            }
            output = output.replacingOccurrences(of: " " + token + " ", with: replacement.hasPrefix("\n") ? replacement : " " + replacement + " ")
            output = output.replacingOccurrences(of: token, with: replacement)
        }
        return output
    }

    private static func formatClipboard(_ raw: String) -> String {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.contains("\n") {
            return "\n" + content + "\n"
        }
        return content
    }

    /// Normalises spacing around inserted content and punctuation.
    private static func tidy(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: " \n", with: "\n")
        output = output.replacingOccurrences(of: "\n ", with: "\n")
        output = output.replacingOccurrences(of: "  ", with: " ")
        output = output.replacingOccurrences(of: " ,", with: ",")
        output = output.replacingOccurrences(of: " .", with: ".")
        return output
    }
}
