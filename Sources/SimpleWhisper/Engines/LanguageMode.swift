import Foundation

/// Which language(s) the speech engine should recognise.
enum LanguageMode: Codable, Equatable, Hashable {
    /// Detect automatically, restricted to `allowed` (ISO 639-1 codes). Empty = any language.
    case auto(allowed: [String])
    /// Always decode in this language.
    case fixed(String)

    static let `default` = LanguageMode.auto(allowed: ["pl", "en"])
    static let any = LanguageMode.auto(allowed: [])

    var title: String {
        switch self {
        case .auto(let allowed) where allowed.isEmpty:
            return "Auto (any language)"
        case .auto(let allowed):
            return "Auto (" + allowed.map { LanguageCatalog.name(for: $0) }.joined(separator: " + ") + ")"
        case .fixed(let code):
            return LanguageCatalog.name(for: code)
        }
    }

    /// Codes the detector may choose from; nil = any language.
    var allowedCodes: [String]? {
        switch self {
        case .auto(let allowed): return allowed.isEmpty ? nil : allowed
        case .fixed(let code): return [code]
        }
    }

    var fixedCode: String? {
        if case .fixed(let code) = self { return code }
        return nil
    }

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    /// Languages to try when an engine must run one pass per language (Apple Speech).
    var candidateCodes: [String] {
        if let fixed = fixedCode { return [fixed] }
        return allowedCodes ?? ["en"]
    }

    /// Parses CLI / legacy values: "auto", "any", "pl", "pl,en", old enum names.
    static func parse(_ raw: String) -> LanguageMode? {
        switch raw {
        case "autoPolishEnglish", "auto": return .default
        case "autoAny", "any": return .any
        case "polish": return .fixed("pl")
        case "english": return .fixed("en")
        default:
            let codes = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            guard !codes.isEmpty, codes.allSatisfy({ LanguageCatalog.names[$0] != nil }) else { return nil }
            return codes.count == 1 ? .fixed(codes[0]) : .auto(allowed: codes)
        }
    }
}

/// Whisper's language list (ISO 639-1 code → English name).
enum LanguageCatalog {
    static let names: [String: String] = [
        "en": "English", "zh": "Chinese", "de": "German", "es": "Spanish", "ru": "Russian", "ko": "Korean",
        "fr": "French", "ja": "Japanese", "pt": "Portuguese", "tr": "Turkish", "pl": "Polish", "ca": "Catalan",
        "nl": "Dutch", "ar": "Arabic", "sv": "Swedish", "it": "Italian", "id": "Indonesian", "hi": "Hindi",
        "fi": "Finnish", "vi": "Vietnamese", "he": "Hebrew", "uk": "Ukrainian", "el": "Greek", "ms": "Malay",
        "cs": "Czech", "ro": "Romanian", "da": "Danish", "hu": "Hungarian", "ta": "Tamil", "no": "Norwegian",
        "th": "Thai", "ur": "Urdu", "hr": "Croatian", "bg": "Bulgarian", "lt": "Lithuanian", "la": "Latin",
        "mi": "Maori", "ml": "Malayalam", "cy": "Welsh", "sk": "Slovak", "te": "Telugu", "fa": "Persian",
        "lv": "Latvian", "bn": "Bengali", "sr": "Serbian", "az": "Azerbaijani", "sl": "Slovenian", "kn": "Kannada",
        "et": "Estonian", "mk": "Macedonian", "br": "Breton", "eu": "Basque", "is": "Icelandic", "hy": "Armenian",
        "ne": "Nepali", "mn": "Mongolian", "bs": "Bosnian", "kk": "Kazakh", "sq": "Albanian", "sw": "Swahili",
        "gl": "Galician", "mr": "Marathi", "pa": "Punjabi", "si": "Sinhala", "km": "Khmer", "sn": "Shona",
        "yo": "Yoruba", "so": "Somali", "af": "Afrikaans", "oc": "Occitan", "ka": "Georgian", "be": "Belarusian",
        "tg": "Tajik", "sd": "Sindhi", "gu": "Gujarati", "am": "Amharic", "yi": "Yiddish", "lo": "Lao",
        "uz": "Uzbek", "fo": "Faroese", "ht": "Haitian Creole", "ps": "Pashto", "tk": "Turkmen", "nn": "Nynorsk",
        "mt": "Maltese", "sa": "Sanskrit", "lb": "Luxembourgish", "my": "Myanmar", "bo": "Tibetan", "tl": "Tagalog",
        "mg": "Malagasy", "as": "Assamese", "tt": "Tatar", "haw": "Hawaiian", "ln": "Lingala", "ha": "Hausa",
        "ba": "Bashkir", "jw": "Javanese", "su": "Sundanese", "yue": "Cantonese",
    ]

    /// All codes sorted by English name.
    static let allCodes: [String] = names.keys.sorted { names[$0]! < names[$1]! }

    static func name(for code: String) -> String {
        names[code] ?? code.uppercased()
    }

    /// Preferred locale identifier for Apple Speech, where the bare code is ambiguous.
    static let preferredLocales: [String: String] = [
        "en": "en-US", "pt": "pt-BR", "zh": "zh-CN", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT",
        "nl": "nl-NL", "sv": "sv-SE", "no": "nb-NO", "ar": "ar-SA", "ko": "ko-KR", "ja": "ja-JP", "pl": "pl-PL",
    ]

    static func locale(for code: String) -> Locale {
        Locale(identifier: preferredLocales[code] ?? code)
    }
}
