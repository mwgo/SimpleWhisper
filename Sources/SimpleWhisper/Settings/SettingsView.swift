import SwiftUI
import AppKit

struct SettingsView: View {
    var controller: DictationController

    var body: some View {
        TabView {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gear") }
            PromptsSettingsView(store: controller.store, settings: controller.settings)
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
            VocabularySettingsView(store: controller.store)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            MacrosSettingsView(store: controller.store)
                .tabItem { Label("Macros", systemImage: "wand.and.stars") }
            AISettingsView(settings: controller.settings)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 460)
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
                Picker("Recognition language", selection: Binding(get: { settings.languageMode }, set: { settings.languageMode = $0 })) {
                    ForEach(LanguageMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Text("Auto (Polish + English) restricts detection to those two languages so short phrases are never mistaken for other Slavic languages.")
                    .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Prompts

struct PromptsSettingsView: View {
    var store: DataStore
    var settings: AppSettings
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
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
                listToolbar(
                    add: {
                        let prompt = NamedPrompt(name: "New prompt", instructions: "", shellCommand: settings.defaultShellCommand)
                        store.prompts.append(prompt)
                        selection = prompt.id
                    },
                    remove: {
                        guard let selection else { return }
                        store.prompts.removeAll { $0.id == selection }
                        if settings.selectedPromptID == selection { settings.selectedPromptID = nil }
                        self.selection = nil
                    },
                    canRemove: selection != nil
                )
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let index = store.prompts.firstIndex(where: { $0.id == selection }) {
                let binding = Binding(get: { store.prompts[index] }, set: { store.prompts[index] = $0 })
                PromptEditor(prompt: binding, settings: settings)
                    .padding()
            } else {
                ContentUnavailableView("Select a prompt", systemImage: "text.bubble", description: Text("Prompts post-process dictated text with AI. Pick one from the HUD or the menu bar."))
            }
        }
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
                TextField("Command", text: $prompt.shellCommand)
                    .font(.system(.body, design: .monospaced))
                Text("Text is written to stdin. {prompt} (or $SW_PROMPT) receives the instructions. stdout becomes the result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Instructions") {
                TextEditor(text: $prompt.instructions)
                    .font(.body)
                    .frame(minHeight: 160)
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
