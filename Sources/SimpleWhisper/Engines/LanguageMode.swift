import Foundation

enum LanguageMode: String, CaseIterable, Codable, Identifiable {
    case autoPolishEnglish
    case polish
    case english
    case autoAny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoPolishEnglish: return "Auto (Polish + English)"
        case .polish: return "Polish"
        case .english: return "English"
        case .autoAny: return "Auto (any language)"
        }
    }

    /// Language codes the detector may choose from. `nil` means any language.
    var allowedCodes: [String]? {
        switch self {
        case .autoPolishEnglish: return ["pl", "en"]
        case .polish: return ["pl"]
        case .english: return ["en"]
        case .autoAny: return nil
        }
    }

    /// A single forced language, if the mode is not automatic.
    var fixedCode: String? {
        switch self {
        case .polish: return "pl"
        case .english: return "en"
        default: return nil
        }
    }
}
