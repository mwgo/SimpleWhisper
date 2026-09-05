import SwiftUI
import AppKit


struct SimpleWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(state: appDelegate.controller.state)
        }
        Settings {
            SettingsView(controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        // Developer aid: SW_OPEN_SETTINGS=1 opens the Settings window right away (for screenshots).
        if ProcessInfo.processInfo.environment["SW_OPEN_SETTINGS"] != nil {
            for delay in [1.0, 2.0, 3.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.activate(ignoringOtherApps: true)
                    let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        || NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    let frames = NSApp.windows.filter { $0.isVisible && $0.title.isEmpty == false }.map { window -> String in
                        let f = window.frame
                        let top = (NSScreen.screens.first?.frame.height ?? 0) - f.maxY
                        return "\(window.title)@\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
                    }
                    DebugLog.write("SW_OPEN_SETTINGS: opened=\(opened) windows=\(frames)")
                }
            }
        }
    }
}

struct MenuBarLabel: View {
    var state: AppState

    var body: some View {
        switch state.phase {
        case .idle: Image(systemName: "mic")
        case .recording: Image(systemName: "mic.fill")
        case .transcribing, .processing: Image(systemName: "waveform")
        }
    }
}

struct MenuContent: View {
    var controller: DictationController

    var body: some View {
        let state = controller.state
        let settings = controller.settings
        let store = controller.store

        Text(state.phase.title)
        if state.isModelLoading { Text(state.modelStatus) }
        if let summary = state.lastSummary { Text(summary) }
        if let anchor = state.hudAnchor { Text("HUD position: \(anchor)") }
        if let error = state.lastError { Text("⚠︎ \(error)") }
        if let hotkeyError = state.hotkeyError {
            Text("⚠︎ \(hotkeyError)")
            Button("Retry key listener") { controller.startHotkey() }
        }
        Divider()

        switch state.phase {
        case .idle:
            Button("Start dictation") { controller.startRecording() }
        case .recording:
            Button("Stop and transcribe") { controller.stopAndTranscribe() }
            Button("Cancel dictation") { controller.cancel() }
        default:
            Button("Cancel dictation") { controller.cancel() }
        }
        Divider()

        Picker("Model", selection: Binding(get: { settings.engineKind }, set: { settings.engineKind = $0; Task { await controller.loadModel() } })) {
            ForEach(EngineKind.allCases) { kind in Text(kind.title).tag(kind) }
        }
        Picker("Language", selection: Binding(get: { settings.languageMode }, set: { settings.languageMode = $0 })) {
            ForEach(settings.languageMenuOptions, id: \.self) { mode in Text(mode.title).tag(mode) }
        }
        Toggle("Spoken punctuation", isOn: Binding(get: { settings.spokenPunctuationEnabled }, set: { settings.spokenPunctuationEnabled = $0 }))
        Picker("Prompt", selection: Binding<UUID?>(get: { settings.selectedPromptID }, set: { settings.selectedPromptID = $0 })) {
            Text("Plain text (no prompt)").tag(UUID?.none)
            ForEach(store.prompts) { prompt in Text(prompt.name).tag(UUID?.some(prompt.id)) }
        }
        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit SimpleWhisper") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
