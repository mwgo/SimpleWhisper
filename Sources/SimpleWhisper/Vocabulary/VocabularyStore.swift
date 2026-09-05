import Foundation

struct VocabularyTerm: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    /// Canonical spelling, e.g. "enova365".
    var text: String
    /// Common misrecognitions, e.g. ["enowa", "e nova"].
    var aliases: [String] = []

    init(id: UUID = UUID(), text: String, aliases: [String] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
    }

    static let defaults: [VocabularyTerm] = []
}
