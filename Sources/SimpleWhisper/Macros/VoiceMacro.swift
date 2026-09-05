import Foundation

enum MacroActionKind: String, Codable, CaseIterable, Identifiable {
    case insertClipboard
    case newLine
    case insertText
    case punctuation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insertClipboard: return "Insert clipboard"
        case .newLine: return "New line"
        case .insertText: return "Insert text"
        case .punctuation: return "Punctuation"
        }
    }
}

struct VoiceMacro: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    /// Spoken trigger words, matched case-insensitively as whole words.
    var keywords: [String]
    var action: MacroActionKind
    /// `.insertText`: the text to insert. `.punctuation`: the mark (`,` `.` `?` … or `\n\n` for a paragraph).
    var text: String = ""

    init(id: UUID = UUID(), keywords: [String], action: MacroActionKind, text: String = "") {
        self.id = id
        self.keywords = keywords
        self.action = action
        self.text = text
    }

    var title: String {
        keywords.first ?? action.title
    }

    static let paragraphMark = "\n\n"

    static let defaults: [VoiceMacro] = [
        VoiceMacro(keywords: ["schowek", "clipboard"], action: .insertClipboard),
        VoiceMacro(keywords: ["nowa linia", "new line"], action: .newLine),
    ] + punctuationDefaults

    /// Spoken punctuation, Polish + English. Seeded once into existing macro files as well.
    static let punctuationDefaults: [VoiceMacro] = [
        VoiceMacro(keywords: ["przecinek", "comma"], action: .punctuation, text: ","),
        VoiceMacro(keywords: ["kropka", "period", "full stop"], action: .punctuation, text: "."),
        VoiceMacro(keywords: ["znak zapytania", "pytajnik", "question mark"], action: .punctuation, text: "?"),
        VoiceMacro(keywords: ["wykrzyknik", "exclamation mark"], action: .punctuation, text: "!"),
        VoiceMacro(keywords: ["dwukropek", "colon"], action: .punctuation, text: ":"),
        VoiceMacro(keywords: ["średnik", "semicolon"], action: .punctuation, text: ";"),
        VoiceMacro(keywords: ["myślnik", "dash"], action: .punctuation, text: "–"),
        VoiceMacro(keywords: ["cudzysłów", "quote"], action: .punctuation, text: "\""),
        VoiceMacro(keywords: ["nawias otwarty", "open paren", "open bracket"], action: .punctuation, text: "("),
        VoiceMacro(keywords: ["nawias zamknięty", "close paren", "close bracket"], action: .punctuation, text: ")"),
        VoiceMacro(keywords: ["nowy akapit", "new paragraph"], action: .punctuation, text: paragraphMark),
    ]
}
