import Foundation

struct VocabularyTerm: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    /// Canonical spelling, e.g. "enova365".
    var text: String
    /// Common misrecognitions, e.g. ["enowa", "e nova"].
    var aliases: [String] = []
    /// Added from a voice macro (not saved): a common word Whisper may get as a hint, but too
    /// ordinary for Parakeet's acoustic boosting, which then forces it onto similar words.
    var isMacroKeyword = false

    private enum CodingKeys: String, CodingKey { case id, text, aliases }

    init(id: UUID = UUID(), text: String, aliases: [String] = [], isMacroKeyword: Bool = false) {
        self.id = id
        self.text = text
        self.aliases = aliases
        self.isMacroKeyword = isMacroKeyword
    }

    static let defaults: [VocabularyTerm] = []
}
