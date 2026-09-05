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
        didSet { defaults.set(try? JSONEncoder().encode(languageMode), forKey: "languageModeJSON") }
    }
    var selectedPromptID: UUID? {
        didSet { defaults.set(selectedPromptID?.uuidString, forKey: "selectedPromptID") }
    }
    var keepTextInClipboard: Bool {
        didSet { defaults.set(keepTextInClipboard, forKey: "keepTextInClipboard") }
    }
    /// Shows the round "run as command" button in the HUD (apply the dictated instruction to selected text).
    var commandModeEnabled: Bool {
        didSet { defaults.set(commandModeEnabled, forKey: "commandModeEnabled") }
    }
    /// Keeps the last dictations/commands in the History submenu.
    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: "historyEnabled") }
    }
    /// When off, punctuation macros ("przecinek", "comma", …) are left as ordinary words.
    var spokenPunctuationEnabled: Bool {
        didSet { defaults.set(spokenPunctuationEnabled, forKey: "spokenPunctuationEnabled") }
    }
    var holdThresholdMs: Int {
        didSet { defaults.set(holdThresholdMs, forKey: "holdThresholdMs") }
    }
    var defaultShellCommand: String {
        didSet { defaults.set(defaultShellCommand, forKey: "defaultShellCommand") }
    }
    /// Shell command used by command mode (instruction applied to selected text).
    var commandShellCommand: String {
        didSet { defaults.set(commandShellCommand, forKey: "commandShellCommand") }
    }
    /// Languages offered for automatic detection (ISO 639-1 codes), edited in Settings.
    var selectedLanguages: [String] {
        didSet {
            defaults.set(selectedLanguages, forKey: "selectedLanguages")
            if case .auto(let allowed) = languageMode, !allowed.isEmpty {
                languageMode = .auto(allowed: selectedLanguages)
            }
        }
    }

    /// Entries for the quick language switch in the menu bar.
    var languageMenuOptions: [LanguageMode] {
        var options: [LanguageMode] = [.auto(allowed: selectedLanguages), .any]
        options += selectedLanguages.map { LanguageMode.fixed($0) }
        if !options.contains(languageMode) { options.append(languageMode) }
        return options
    }

    init() {
        engineKind = EngineKind(rawValue: defaults.string(forKey: "engineKind") ?? "") ?? .whisperSmall
        if let data = defaults.data(forKey: "languageModeJSON"), let mode = try? JSONDecoder().decode(LanguageMode.self, from: data) {
            languageMode = mode
        } else {
            languageMode = LanguageMode.parse(defaults.string(forKey: "languageMode") ?? "") ?? .default
        }
        selectedPromptID = defaults.string(forKey: "selectedPromptID").flatMap(UUID.init(uuidString:))
        keepTextInClipboard = defaults.object(forKey: "keepTextInClipboard") as? Bool ?? false
        spokenPunctuationEnabled = defaults.object(forKey: "spokenPunctuationEnabled") as? Bool ?? true
        commandModeEnabled = defaults.object(forKey: "commandModeEnabled") as? Bool ?? false
        historyEnabled = defaults.object(forKey: "historyEnabled") as? Bool ?? false
        holdThresholdMs = defaults.object(forKey: "holdThresholdMs") as? Int ?? 400
        defaultShellCommand = defaults.string(forKey: "defaultShellCommand") ?? NamedPrompt.defaultShellCommand
        commandShellCommand = defaults.string(forKey: "commandShellCommand") ?? NamedPrompt.defaultCommandShellCommand
        selectedLanguages = defaults.stringArray(forKey: "selectedLanguages") ?? ["pl", "en"]
    }
}

/// JSON-file-backed lists: prompts, vocabulary, macros.
@Observable
final class DataStore {
    var prompts: [NamedPrompt] { didSet { save(prompts, to: "prompts.json") } }
    var vocabulary: [VocabularyTerm] { didSet { save(vocabulary, to: "vocabulary.json") } }
    var macros: [VoiceMacro] { didSet { save(macros, to: "macros.json") } }
    var history: [HistoryEntry] { didSet { save(history, to: "history.json") } }

    static let directory: URL = {
        // SW_DATA_DIR overrides the data folder (used by the demo/test modes).
        if let override = ProcessInfo.processInfo.environment["SW_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SimpleWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        prompts = Self.load("prompts.json") ?? NamedPrompt.defaults
        vocabulary = Self.load("vocabulary.json") ?? VocabularyTerm.defaults
        macros = Self.load("macros.json") ?? VoiceMacro.defaults
        history = Self.load("history.json") ?? []
        seedPunctuationMacrosIfNeeded()
    }

    func addHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > HistoryEntry.maxStored { history.removeLast(history.count - HistoryEntry.maxStored) }
    }

    /// Entries shown in the menu (newest first).
    var recentHistory: [HistoryEntry] { Array(history.prefix(HistoryEntry.maxShown)) }


    /// Adds the default punctuation macros once to macro files created before they existed.
    private func seedPunctuationMacrosIfNeeded() {
        let key = "punctuationMacrosSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if !macros.contains(where: { $0.action == .punctuation }) {
            macros.append(contentsOf: VoiceMacro.punctuationDefaults)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Macros in effect: punctuation macros are dropped when spoken punctuation is off.
    func activeMacros(spokenPunctuation: Bool) -> [VoiceMacro] {
        spokenPunctuation ? macros : macros.filter { $0.action != .punctuation }
    }

    /// Vocabulary passed to the speech engines: user terms plus macro keywords.
    func effectiveVocabulary(spokenPunctuation: Bool) -> [VocabularyTerm] {
        var terms = vocabulary.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let known = Set(terms.map { $0.text.lowercased() })
        for macro in activeMacros(spokenPunctuation: spokenPunctuation) {
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
