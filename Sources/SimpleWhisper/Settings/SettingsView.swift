import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    var controller: DictationController
    @State private var tab: String = ProcessInfo.processInfo.environment["SW_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gear") }
                .tag("general")
            LanguageSettingsView(settings: controller.settings)
                .tabItem { Label("Languages", systemImage: "globe") }
                .tag("languages")
            PromptsSettingsView(store: controller.store, settings: controller.settings)
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag("prompts")
            VocabularySettingsView(store: controller.store)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag("vocabulary")
            MacrosSettingsView(store: controller.store, settings: controller.settings)
                .tabItem { Label("Macros", systemImage: "wand.and.stars") }
                .tag("macros")
            AISettingsView(settings: controller.settings)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag("ai")
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 760, height: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .task {
            // Developer aid: SW_SETTINGS_CYCLE=1 switches tabs every second (crash test for --settings-demo).
            guard ProcessInfo.processInfo.environment["SW_SETTINGS_CYCLE"] != nil else { return }
            let tabs = ["general", "languages", "prompts", "vocabulary", "macros", "ai", "about"]
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                index = (index + 1) % tabs.count
                tab = tabs[index]
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var controller: DictationController
    @State private var permissionsTick = 0
    @State private var launchAtLogin = LaunchAtLogin()

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
            Section("Hotkey") {
                Picker("Dictation key", selection: Binding(get: { settings.hotkeyKey }, set: { settings.hotkeyKey = $0; controller.applyHotkeySettings() })) {
                    ForEach(HotkeyKey.allCases) { key in Text(key.title).tag(key) }
                }
                HotkeyLegend(key: settings.hotkeyKey, doublePress: settings.fnDoublePress, commandMode: settings.commandModeEnabled)
                Stepper("Hold threshold: \(settings.holdThresholdMs) ms", value: Binding(get: { settings.holdThresholdMs }, set: { settings.holdThresholdMs = $0; controller.applyHotkeySettings() }), in: 200...1000, step: 50)
                Toggle("Require a double press", isOn: Binding(get: { settings.fnDoublePress }, set: { settings.fnDoublePress = $0; controller.applyHotkeySettings() }))
                if settings.fnDoublePress {
                    Stepper("Double-press window: \(settings.doublePressWindowMs) ms", value: Binding(get: { settings.doublePressWindowMs }, set: { settings.doublePressWindowMs = $0; controller.applyHotkeySettings() }), in: 200...800, step: 50)
                }
                if settings.hotkeyKey == .fn {
                    Text("System Settings › Keyboard › “Press 🌐 key to” must be set to “Do Nothing”.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Shortcuts with this modifier (e.g. ⌘C) keep working: a second key pressed while it is held cancels the recording silently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("HUD") {
                Picker("Position", selection: Binding(get: { settings.hudPlacement }, set: { settings.hudPlacement = $0 })) {
                    ForEach(HUDPlacement.allCases) { placement in Text(placement.title).tag(placement) }
                }
                Toggle("Show status text (otherwise only the animation)", isOn: Binding(get: { settings.hudShowsText }, set: { settings.hudShowsText = $0 }))
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(HUDTheme.allCases) { theme in
                            Button {
                                settings.hudTheme = theme
                            } label: {
                                Circle()
                                    .fill(theme.background)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(settings.hudTheme == theme ? 0.9 : 0.15), lineWidth: settings.hudTheme == theme ? 2 : 1))
                                    .overlay {
                                        if settings.hudTheme == theme {
                                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.ink)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(theme.title)
                        }
                        Text(settings.hudTheme.title).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                Text("The small green status capsule shown while recording and processing. “Near the text caret” falls back to the focused field, then to the bottom of the screen. With “Do not show” the menu bar icon is the only indicator; the ▶ command button is then unavailable, so run commands with the Control key or from the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Toggle("Keep dictated text in the clipboard after pasting", isOn: Binding(get: { settings.keepTextInClipboard }, set: { settings.keepTextInClipboard = $0 }))
            }
            Section("History") {
                Toggle("Keep a history of recent dictations and commands", isOn: Binding(get: { settings.historyEnabled }, set: { settings.historyEnabled = $0 }))
                Text("“History…” in the menu bar opens a window with the last 10 entries (date, text). Clicking an entry copies its text to the clipboard. Stored locally in history.json.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Command mode") {
                Toggle("Enable command mode (▶ button in the HUD)", isOn: Binding(get: { settings.commandModeEnabled }, set: { settings.commandModeEnabled = $0 }))
                Text("Select text in your editor, start dictation, say what to do with it (e.g. “convert to markdown”), then click the round ▶ button on the right of the HUD or press Control (works while holding fn or after a short fn press). The selection is sent to the command-mode AI command from the AI tab together with your instruction, and the result replaces the selection. With nothing selected, the dictation is a direct question to the assistant and the answer opens as a Markdown document.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch SimpleWhisper at login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }))
                HStack {
                    Text(launchAtLogin.statusDescription).font(.caption).foregroundStyle(.secondary)
                    if launchAtLogin.errorMessage != nil || SMAppService.mainApp.status == .requiresApproval {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
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

// MARK: - Hotkey legend

/// Readable summary of the keyboard controls, adapting to the double-press setting.
struct HotkeyLegend: View {
    var key: HotkeyKey
    var doublePress: Bool
    var commandMode: Bool

    var body: some View {
        let k = key.symbol
        VStack(alignment: .leading, spacing: 6) {
            if doublePress {
                row("\(k)  ×2", "two quick presses start dictation, one press stops it")
                row("\(k), then \(k) (hold)", "push-to-talk: release the second press to stop")
                row("\(k)  ×1", "does nothing, so accidental taps never record")
            } else {
                row("\(k) (tap)", "start / stop dictation")
                row("\(k) (hold)", "push-to-talk: release to stop")
            }
            row("esc", "cancel recording or processing")
            row("letter / space", "while recording: pick the prompt with that shortcut / plain text")
            if commandMode {
                row("⌃ control", "while recording: run the dictation as a command")
            }
            row("\(k) + any key", "keyboard shortcut: recording is cancelled silently")
        }
        .padding(.vertical, 2)
    }

    private func row(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys).font(.system(.body, design: .rounded).weight(.semibold)).frame(width: 210, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Language

struct LanguageSettingsView: View {
    var settings: AppSettings

    var body: some View {
        Form {
            Section("Recognition language") {
                LanguageSettingsSection(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}

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
                .frame(height: 230)
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
                            Spacer()
                            if !prompt.shortcut.isEmpty {
                                Text(prompt.shortcut.uppercased())
                                    .font(.caption.weight(.semibold).monospaced())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
                            }
                            if settings.selectedPromptID == prompt.id {
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
            TextField("Shortcut key (one letter or digit)", text: Binding(
                get: { prompt.shortcut },
                set: { value in prompt.shortcut = String(value.lowercased().filter { $0.isLetter || $0.isNumber }.suffix(1)) }
            ))
            Text("Press this key while recording to use the prompt for that dictation. Space selects plain text (no prompt).")
                .font(.caption).foregroundStyle(.secondary)
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
                    Text("Text is written to stdin. {prompt} (or $SW_PROMPT) receives the instructions, {tools} the tool flags (Settings › AI › Tools). stdout becomes the result.")
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
            HStack {
                Text("Term").frame(width: 200, alignment: .leading)
                Text("Aliases (comma-separated misrecognitions)")
                Spacer()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
            List {
                ForEach(store.vocabulary) { term in
                    HStack(spacing: 8) {
                        TextField("Term", text: binding(for: term.id, keyPath: \.text))
                            .frame(width: 200)
                        TextField("e.g. enowa, e nova", text: aliasesBinding(for: term.id))
                        Button {
                            store.vocabulary.removeAll { $0.id == term.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove term")
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            listToolbar(
                add: {
                    let term = VocabularyTerm(text: "")
                    store.vocabulary.append(term)
                    selection = term.id
                },
                remove: { store.vocabulary.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } },
                canRemove: store.vocabulary.contains { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
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
    var settings: AppSettings
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Spoken keywords replaced in the dictated text. “Insert clipboard” pastes what was in the clipboard when recording started. “Punctuation” inserts a mark with proper spacing (say “przecinek”, “kropka”, “new paragraph”…).")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            Toggle("Spoken punctuation", isOn: Binding(get: { settings.spokenPunctuationEnabled }, set: { settings.spokenPunctuationEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 8)
            HStack {
                Text("Keywords (comma-separated)").frame(width: 240, alignment: .leading)
                Text("Action").frame(width: 150, alignment: .leading)
                Text("Text")
                Spacer()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
            List {
                ForEach(store.macros) { macro in
                    HStack(spacing: 8) {
                        TextField("schowek, clipboard", text: keywordsBinding(for: macro.id))
                            .frame(width: 240)
                        Picker("", selection: actionBinding(for: macro.id)) {
                            ForEach(MacroActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        if macro.action == .insertText {
                            TextField("Text to insert", text: textBinding(for: macro.id))
                        } else if macro.action == .punctuation {
                            TextField("Mark, e.g. , . ? or ⏎⏎", text: punctuationBinding(for: macro.id))
                                .frame(width: 90)
                                .font(.system(.body, design: .monospaced))
                            Text(macro.text == VoiceMacro.paragraphMark ? "paragraph break" : "")
                                .foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            store.macros.removeAll { $0.id == macro.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove macro")
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            listToolbar(
                add: {
                    let macro = VoiceMacro(keywords: [], action: .insertText)
                    store.macros.append(macro)
                    selection = macro.id
                },
                remove: { store.macros.removeAll { $0.keywords.isEmpty && $0.text.isEmpty } },
                canRemove: store.macros.contains { $0.keywords.isEmpty && $0.text.isEmpty }
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

    /// Shows the paragraph mark as ⏎⏎ while storing "\n\n".
    private func punctuationBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                let text = store.macros.first { $0.id == id }?.text ?? ""
                return text == VoiceMacro.paragraphMark ? "⏎⏎" : text
            },
            set: { value in
                if let i = index(of: id) {
                    store.macros[i].text = (value == "⏎⏎" || value == "⏎") ? VoiceMacro.paragraphMark : value
                }
            }
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
                TextField("Command", text: Binding(get: { settings.defaultShellCommand }, set: { settings.defaultShellCommand = $0 }), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                Text("Runs in /bin/zsh -lc. The dictated text is piped to stdin, {prompt} is replaced with the prompt instructions (quoted), {tools} with the tool flags from the Tools section, stdout is used as the result.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to default") { settings.defaultShellCommand = NamedPrompt.defaultShellCommand }
            }
            Section("Tools") {
                Toggle("Allow Claude to use the web (WebFetch, WebSearch)", isOn: Binding(get: { settings.allowWebAccess }, set: { settings.allowWebAccess = $0 }))
                Text("In print mode Claude cannot ask for permissions, so tools are off by default ({tools} → --tools \"\"): faster, and the model cannot read local files. When on, {tools} becomes --tools WebFetch WebSearch --allowedTools WebFetch WebSearch, so prompts and commands may look things up online (slower).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Result window") {
                Toggle("Ask for Markdown when the result cannot be pasted", isOn: Binding(get: { settings.markdownWhenNotPasting }, set: { settings.markdownWhenNotPasting = $0 }))
                Text("When no text field is active at the start of dictation, the result is shown in a window instead of being pasted. With this on, prompts and commands ask the AI for Markdown, and the window renders it (switch to Source to edit).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Command mode command") {
                TextField("Command", text: Binding(get: { settings.commandShellCommand }, set: { settings.commandShellCommand = $0 }), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                Text("Used when you press ▶ in the HUD to apply a dictated instruction to selected text. Editing real text deserves a stronger model, so the default uses --model opus (slower than haiku).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to default") { settings.commandShellCommand = NamedPrompt.defaultCommandShellCommand }
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
            .help("Remove empty rows (use the trash icon to remove a specific row)")
        Spacer()
    }
    .buttonStyle(.borderless)
    .padding(6)
}
