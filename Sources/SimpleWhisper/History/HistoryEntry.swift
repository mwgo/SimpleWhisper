import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case dictation
        case command
    }

    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    /// Final text that was pasted.
    var text: String
    /// Command mode: the dictated instruction.
    var instruction: String? = nil
    var language: String? = nil

    static let maxStored = 50
    static let maxShown = 10

    /// One-line label for the menu: time, kind, and the beginning of the text.
    var menuTitle: String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        let body = (kind == .command ? "▶ \(instruction ?? "") → " : "") + text
        let flat = body.replacingOccurrences(of: "\n", with: " ⏎ ")
        let clipped = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
        return "\(time)  \(clipped)"
    }
}
