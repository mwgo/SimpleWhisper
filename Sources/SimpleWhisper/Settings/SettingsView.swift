import SwiftUI
import AppKit

struct SettingsView: View {
    var controller: DictationController
    @State private var tab: String = ProcessInfo.processInfo.environment["SW_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gear") }
                .tag("general")
            PromptsSettingsView(store: controller.store, settings: controller.settings)
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag("prompts")
            VocabularySettingsView(store: controller.store)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag("vocabulary")
            MacrosSettingsView(store: controller.store)
                .tabItem { Label("Macros", systemImage: "wand.and.stars") }
                .tag("macros")
            AISettingsView(settings: controller.settings)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag("ai")
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 700, height: 480)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var controller: DictationController
    @State private var permissionsTick = 0

    var body: some View {
        let settings = controller.settings
        let state = controller.state
        Form {
            Section("Speech model") {
                Picker("Model", selection: Binding(get: { settings.engineKind }, set: { settings.engineKind = $0 })) {
                    ForEach(EngineKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                Text(settings.engineKind.subtitle).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(state.isModelLoading ? "Loading…" : "Load model now") { Task { await controller.loadModel() } }
                        .disabled(state.isModelLoading)
                    Text(state.modelStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Language") {
                LanguageSettingsSection(settings: settings)
            }
            Section("Hotkey") {
                Text("Globe/fn: short press toggles dictation, hold for push-to-talk. Escape cancels.")
                Stepper("Hold threshold: \(settings.holdThresholdMs) ms", value: Binding(get: { settings.holdThresholdMs }, set: { settings.holdThresholdMs = $0; controller.startHotkey() }), in: 200...1000, step: 50)
                Text("System Settings › Keyboard › “Press 🌐 key to” must be set to “Do Nothing”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Toggle("Keep dictated text in the clipboard after pasting", isOn: Binding(get: { settings.keepTextInClipboard }, set: { settings.keepTextInClipboard = $0 }))
            }
            Section("Permissions") {
                permissionRow("Microphone", granted: Permissions.microphoneGranted) {
                    Task { _ = await Permissions.requestMicrophone(); permissionsTick += 1 }
                    Permissions.openSystemSettings(.microphone)
                }
                permissionRow("Accessibility (paste, caret position, key listener)", granted: Permissions.accessibilityGranted) {
                    Permissions.requestAccessibility()
                    Permissions.openSystemSettings(.accessibility)
                }
                permissionRow("Input Monitoring (Globe/fn key)", granted: Permissions.inputMonitoringGranted) {
                    Permissions.requestInputMonitoring()
                    Permissions.openSystemSettings(.inputMonitoring)
                }
                if !controller.isHotkeyRunning {
                    Button("Retry key listener") { controller.startHotkey(); permissionsTick += 1 }
                }
            }
        }
        .formStyle(.grouped)
        .id(permissionsTick)
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}

// MARK: - Language

struct LanguageSettingsSection: View {
    var settings: AppSettings
    @State private var filter = ""

    private enum ModeKind: String, CaseIterable, Identifiable {
        case selected, fixed, any
        var id: String { rawValue }
        var title: String {
            switch self {
            case .selected: return "Auto-detect among selected languages"
            case .fixed: return "Always one language"
            case .any: return "Auto-detect any language"
            }
        }
    }

    private var modeKind: Binding<ModeKind> {
        Binding(
            get: {
                switch settings.languageMode {
                case .auto(let allowed): return allowed.isEmpty ? .any : .selected
                case .fixed: return .fixed
                }
            },
            set: { kind in
                switch kind {
                case .selected: settings.languageMode = .auto(allowed: settings.selectedLanguages)
                case .any: settings.languageMode = .any
                case .fixed: settings.languageMode = .fixed(settings.languageMode.fixedCode ?? settings.selectedLanguages.first ?? "en")
                }
            }
        )
    }

    var body: some View {
        Picker("Recognition", selection: modeKind) {
            ForEach(ModeKind.allCases) { kind in Text(kind.title).tag(kind) }
        }
        switch modeKind.wrappedValue {
        case .selected:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Languages")
                    Spacer()
                    TextField("", text: $filter, prompt: Text("Filter…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 200)
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 4) {
                        ForEach(filteredCodes, id: \.self) { code in
                            Toggle(isOn: languageToggle(code)) {
                                HStack(spacing: 4) {
                                    Text(LanguageCatalog.name(for: code)).lineLimit(1)
                                    Text(code).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Text("Selected: " + settings.selectedLanguages.map { LanguageCatalog.name(for: $0) }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Detection is restricted to the selected languages, so short phrases are never mistaken for a similar language. Mixed sentences are fine; the dominant language decides.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .fixed:
            Picker("Language", selection: Binding(
                get: { settings.languageMode.fixedCode ?? "en" },
                set: { settings.languageMode = .fixed($0) }
            )) {
                ForEach(LanguageCatalog.allCodes, id: \.self) { code in
                    Text("\(LanguageCatalog.name(for: code)) (\(code))").tag(code)
                }
            }
        case .any:
            Text("Whisper and Parakeet detect the language themselves; Apple Speech falls back to the selected languages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filteredCodes: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let codes = LanguageCatalog.allCodes
        let selectedFirst = codes.sorted { a, b in
            let sa = settings.selectedLanguages.contains(a), sb = settings.selectedLanguages.contains(b)
            if sa != sb { return sa }
            return LanguageCatalog.name(for: a) < LanguageCatalog.name(for: b)
        }
        guard !query.isEmpty else { return selectedFirst }
        return selectedFirst.filter { code in
            LanguageCatalog.name(for: code).lowercased().hasPrefix(query) || code.hasPrefix(query)
        }
    }

    private func languageToggle(_ code: String) -> Binding<Bool> {
        Binding(
            get: { settings.selectedLanguages.contains(code) },
            set: { on in
                var list = settings.selectedLanguages
                if on, !list.contains(code) { list.append(code) }
                if !on { list.removeAll { $0 == code } }
                if list.isEmpty { list = ["en"] }
                settings.selectedLanguages = list
            }
        )
    }
}

// MARK: - Prompts

struct PromptsSettingsView: View {
    var store: DataStore
    var settings: AppSettings
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.prompts) { prompt in
                        HStack {
                            Text(prompt.name.isEmpty ? "Untitled" : prompt.name)
                            if settings.selectedPromptID == prompt.id {
                                Spacer()
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .tag(prompt.id)
                    }
                    .onMove { store.prompts.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                Divider()
                listToolbar(
                    add: {
                        let prompt = NamedPrompt(name: "New prompt", instructions: "", shellCommand: settings.defaultShellCommand)
                        store.prompts.append(prompt)
                        selection = prompt.id
                    },
                    remove: {
                        guard let selection else { return }
                        self.selection = nil
                        if settings.selectedPromptID == selection { settings.selectedPromptID = nil }
                        store.prompts.removeAll { $0.id == selection }
                    },
                    canRemove: selection != nil
                )
            }
            .frame(width: 200)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Group {
                if let selected = selection, let current = store.prompts.first(where: { $0.id == selected }) {
                    // Look the prompt up by id on every access: an index would go stale when the row is removed.
                    let binding = Binding(
                        get: { store.prompts.first(where: { $0.id == selected }) ?? current },
                        set: { value in
                            if let index = store.prompts.firstIndex(where: { $0.id == selected }) {
                                store.prompts[index] = value
                            }
                        }
                    )
                    PromptEditor(prompt: binding, settings: settings)
                        .id(selected)
                } else {
                    ContentUnavailableView("Select a prompt", systemImage: "text.bubble", description: Text("Prompts post-process dictated text with AI. Pick one from the HUD or the menu bar."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if selection == nil { selection = store.prompts.first?.id } }
    }
}

struct PromptEditor: View {
    @Binding var prompt: NamedPrompt
    var settings: AppSettings

    var body: some View {
        Form {
            TextField("Name", text: $prompt.name)
            Picker("Provider", selection: $prompt.provider) {
                ForEach(PromptProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }
            if prompt.provider == .shell {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                    TextField("", text: $prompt.shellCommand, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...3)
                    Text("Text is written to stdin. {prompt} (or $SW_PROMPT) receives the instructions. stdout becomes the result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                TextEditor(text: $prompt.instructions)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            Toggle("Use this prompt for dictation", isOn: Binding(
                get: { settings.selectedPromptID == prompt.id },
                set: { settings.selectedPromptID = $0 ? prompt.id : nil }
            ))
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vocabulary

struct VocabularySettingsView: View {
    var store: DataStore
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Words the models tend to get wrong. Whisper gets them as a prompt, Parakeet as acoustic boosting, and aliases are always corrected in the final text.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            Table(store.vocabulary, selection: $selection) {
                TableColumn("Term") { term in
                    TextField("Term", text: binding(for: term.id, keyPath: \.text))
                }
                TableColumn("Aliases (comma-separated misrecognitions)") { term in
                    TextField("e.g. enowa, e nova", text: aliasesBinding(for: term.id))
                }
                TableColumn("") { term in
                    Button {
                        if selection == term.id { selection = nil }
                        store.vocabulary.removeAll { $0.id == term.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove term")
                }
                .width(28)
            }
            listToolbar(
                add: {
                    let term = VocabularyTerm(text: "")
                    store.vocabulary.append(term)
                    selection = term.id
                },
                remove: {
                    guard let selection else { return }
                    store.vocabulary.removeAll { $0.id == selection }
                    self.selection = nil
                },
                canRemove: selection != nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for id: UUID, keyPath: WritableKeyPath<VocabularyTerm, String>) -> Binding<String> {
        Binding(
            get: { store.vocabulary.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let index = store.vocabulary.firstIndex(where: { $0.id == id }) {
                    store.vocabulary[index][keyPath: keyPath] = value
                }
            }
        )
    }

    private func aliasesBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.vocabulary.first { $0.id == id }?.aliases.joined(separator: ", ") ?? "" },
            set: { value in
                if let index = store.vocabulary.firstIndex(where: { $0.id == id }) {
                    store.vocabulary[index].aliases = splitList(value)
                }
            }
        )
    }
}

// MARK: - Macros

struct MacrosSettingsView: View {
    var store: DataStore
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Spoken keywords replaced in the dictated text. “Insert clipboard” pastes what was in the clipboard when recording started.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            Table(store.macros, selection: $selection) {
                TableColumn("Keywords (comma-separated)") { macro in
                    TextField("schowek, clipboard", text: keywordsBinding(for: macro.id))
                }
                TableColumn("Action") { macro in
                    Picker("", selection: actionBinding(for: macro.id)) {
                        ForEach(MacroActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .labelsHidden()
                }
                .width(150)
                TableColumn("Text") { macro in
                    if macro.action == .insertText {
                        TextField("Text to insert", text: textBinding(for: macro.id))
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                TableColumn("") { macro in
                    Button {
                        if selection == macro.id { selection = nil }
                        store.macros.removeAll { $0.id == macro.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove macro")
                }
                .width(28)
            }
            listToolbar(
                add: {
                    let macro = VoiceMacro(keywords: [], action: .insertText)
                    store.macros.append(macro)
                    selection = macro.id
                },
                remove: {
                    guard let selection else { return }
                    store.macros.removeAll { $0.id == selection }
                    self.selection = nil
                },
                canRemove: selection != nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func index(of id: UUID) -> Int? { store.macros.firstIndex { $0.id == id } }

    private func keywordsBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.macros.first { $0.id == id }?.keywords.joined(separator: ", ") ?? "" },
            set: { value in if let i = index(of: id) { store.macros[i].keywords = splitList(value) } }
        )
    }

    private func actionBinding(for id: UUID) -> Binding<MacroActionKind> {
        Binding(
            get: { store.macros.first { $0.id == id }?.action ?? .insertText },
            set: { value in if let i = index(of: id) { store.macros[i].action = value } }
        )
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { store.macros.first { $0.id == id }?.text ?? "" },
            set: { value in if let i = index(of: id) { store.macros[i].text = value } }
        )
    }
}

// MARK: - AI

struct AISettingsView: View {
    var settings: AppSettings

    var body: some View {
        Form {
            Section("Apple Intelligence (on-device)") {
                LabeledContent("Status", value: FoundationModelsProcessor.availabilityDescription)
                Text("Free, private, no network. Requires Apple Intelligence enabled in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shell command (default for new prompts)") {
                TextField("Command", text: Binding(get: { settings.defaultShellCommand }, set: { settings.defaultShellCommand = $0 }))
                    .font(.system(.body, design: .monospaced))
                Text("Runs in /bin/zsh -lc. The dictated text is piped to stdin, {prompt} is replaced with the prompt instructions (quoted), stdout is used as the result. Example: claude -p --no-session-persistence --model haiku --setting-sources \"\" --disable-slash-commands --system-prompt {prompt}")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to default") { settings.defaultShellCommand = NamedPrompt.defaultShellCommand }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "-"
        return "Version \(short) (\(build))"
    }

    private let components: [(String, String, String)] = [
        ("WhisperKit", "Argmax · OpenAI Whisper on CoreML", "https://github.com/argmaxinc/argmax-oss-swift"),
        ("FluidAudio", "NVIDIA Parakeet TDT 0.6B v3 on CoreML", "https://github.com/FluidInference/FluidAudio"),
        ("Apple Speech", "SpeechAnalyzer / DictationTranscriber (macOS 26)", "https://developer.apple.com/documentation/speech"),
        ("Claude Code CLI", "AI post-processing via `claude -p`", "https://claude.com/claude-code"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(radius: 6, y: 3)
            VStack(spacing: 4) {
                Text("SimpleWhisper").font(.title2.weight(.semibold))
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
            Text("Local dictation for macOS. Press the Globe/fn key, speak in any of many languages, and the text lands in your editor. Speech models run on-device; optional AI prompts clean up or transform the text.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Text("SimpleWhisper is completely free. No subscription, no account, no tracking.")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Divider().frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 6) {
                Text("Built with").font(.headline)
                ForEach(components, id: \.0) { name, description, url in
                    HStack(alignment: .firstTextBaseline) {
                        Link(name, destination: URL(string: url)!)
                            .frame(width: 130, alignment: .leading)
                        Text(description).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Open data folder") { NSWorkspace.shared.open(DataStore.directory) }
                Button("Open debug log") { NSWorkspace.shared.open(DataStore.directory.appendingPathComponent("debug.log")) }
            }
            Text("© 2026 Marcin Wojas").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private func splitList(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func listToolbar(add: @escaping () -> Void, remove: @escaping () -> Void, canRemove: Bool) -> some View {
    HStack(spacing: 0) {
        Button(action: add) { Image(systemName: "plus") }
        Divider().frame(height: 16)
        Button(action: remove) { Image(systemName: "minus") }.disabled(!canRemove)
        Spacer()
    }
    .buttonStyle(.borderless)
    .padding(6)
}
