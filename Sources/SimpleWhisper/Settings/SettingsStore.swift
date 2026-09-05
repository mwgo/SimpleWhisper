import Foundation
import Observation

/// Simple, UserDefaults-backed preferences.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var engineKind: EngineKind {
        didSet { defaults.set(engineKind.rawValue, forKey: "engineKind") }
    }
    var languageMode: LanguageMode {
        didSet { defaults.set(languageMode.rawValue, forKey: "languageMode") }
    }
    var selectedPromptID: UUID? {
        didSet { defaults.set(selectedPromptID?.uuidString, forKey: "selectedPromptID") }
    }
    var keepTextInClipboard: Bool {
        didSet { defaults.set(keepTextInClipboard, forKey: "keepTextInClipboard") }
    }
    var holdThresholdMs: Int {
        didSet { defaults.set(holdThresholdMs, forKey: "holdThresholdMs") }
    }
    var defaultShellCommand: String {
        didSet { defaults.set(defaultShellCommand, forKey: "defaultShellCommand") }
    }

    init() {
        engineKind = EngineKind(rawValue: defaults.string(forKey: "engineKind") ?? "") ?? .whisperSmall
        languageMode = LanguageMode(rawValue: defaults.string(forKey: "languageMode") ?? "") ?? .autoPolishEnglish
        selectedPromptID = defaults.string(forKey: "selectedPromptID").flatMap(UUID.init(uuidString:))
        keepTextInClipboard = defaults.object(forKey: "keepTextInClipboard") as? Bool ?? false
        holdThresholdMs = defaults.object(forKey: "holdThresholdMs") as? Int ?? 400
        defaultShellCommand = defaults.string(forKey: "defaultShellCommand") ?? NamedPrompt.defaultShellCommand
    }
}

/// JSON-file-backed lists: prompts, vocabulary, macros.
@Observable
final class DataStore {
    var prompts: [NamedPrompt] { didSet { save(prompts, to: "prompts.json") } }
    var vocabulary: [VocabularyTerm] { didSet { save(vocabulary, to: "vocabulary.json") } }
    var macros: [VoiceMacro] { didSet { save(macros, to: "macros.json") } }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SimpleWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        prompts = Self.load("prompts.json") ?? NamedPrompt.defaults
        vocabulary = Self.load("vocabulary.json") ?? VocabularyTerm.defaults
        macros = Self.load("macros.json") ?? VoiceMacro.defaults
    }

    /// Vocabulary passed to the speech engines: user terms plus macro keywords.
    var effectiveVocabulary: [VocabularyTerm] {
        var terms = vocabulary.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let known = Set(terms.map { $0.text.lowercased() })
        for macro in macros {
            for keyword in macro.keywords where !known.contains(keyword.lowercased()) && keyword.count >= 3 {
                terms.append(VocabularyTerm(text: keyword))
            }
        }
        return terms
    }

    private static func load<T: Decodable>(_ name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
    }
}
