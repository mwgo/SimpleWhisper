import Foundation

enum MacroActionKind: String, Codable, CaseIterable, Identifiable {
    case insertClipboard
    case newLine
    case insertText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insertClipboard: return "Insert clipboard"
        case .newLine: return "New line"
        case .insertText: return "Insert text"
        }
    }
}

struct VoiceMacro: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    /// Spoken trigger words, matched case-insensitively as whole words.
    var keywords: [String]
    var action: MacroActionKind
    /// Used only by `.insertText`.
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

    static let defaults: [VoiceMacro] = [
        VoiceMacro(keywords: ["schowek", "clipboard"], action: .insertClipboard),
        VoiceMacro(keywords: ["nowa linia", "new line"], action: .newLine),
    ]
}
