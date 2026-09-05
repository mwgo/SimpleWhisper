import SwiftUI
import Foundation
import AppKit
import WhisperKit

/// Program entry point. Without arguments it starts the menu bar app; with `--transcribe`
/// it runs the dictation pipeline on an audio file and prints the result (used for testing).
@main
enum Entry {
    static func main() {
        setbuf(stdout, nil)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--transcribe") || arguments.contains("--help") || arguments.contains("--apple-locales") {
            // handled below
        }
        if arguments.contains("--transcribe") || arguments.contains("--help") || arguments.contains("--apple-locales") {
            setbuf(stdout, nil)
            Task {
                let exitCode = await DebugCLI.run(arguments)
                exit(exitCode)
            }
            // Keep the main run loop alive: the speech frameworks dispatch work to the main queue.
            RunLoop.main.run()
            return
        }
        if arguments.contains("--hud-demo") {
            HUDDemo.run()
            return
        }
        if arguments.contains("--settings-demo") {
            SettingsDemo.run()
            return
        }
        SimpleWhisperApp.main()
    }
}

/// Shows the HUD in every stage (5 s each) at the screen centre, for visual checks: `--hud-demo`.
@MainActor
enum HUDDemo {
    private static var hud: HUDWindowController?
    private static var timer: Timer?

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = HUDWindowController()
        hud = controller
        let stages: [(String, String?, HUDStage)] = [
            ("Recording", "Clean up", .recording),
            ("Transcribing…", nil, .transcribing),
            ("Processing", "PL · Translate to English · 3s", .processing),
            ("Cancelled", nil, .message),
        ]
        var index = 0
        controller.show(text: stages[0].0, detail: stages[0].1, stage: stages[0].2)
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            tick += 1
            let level = (sin(Double(tick) / 3) + 1) / 2 * 0.7 + Double.random(in: 0...0.3)
            controller.setLevel(level)
            if tick % 60 == 0 {
                index = (index + 1) % stages.count
                let stage = stages[index]
                controller.update(text: stage.0, detail: stage.1, stage: stage.2)
            }
        }
        app.run()
    }
}


enum DebugCLI {
    static let usage = """
    Usage: SimpleWhisper --transcribe <audio file> [--engine <kind>] [--language <mode>]
                         [--prompt <name>] [--clipboard <text>] [--no-vocabulary]

      --engine     whisperSmall (default) | whisperLargeV3Turbo | whisperLargeV3Compressed | parakeetV3 | appleSpeech
      --language   auto (default: pl+en) | any | <code> | <code,code,...> e.g. pl,en,de
      --prompt     name of a saved prompt to post-process the text with AI
      --clipboard  text used for the clipboard macro (default: current clipboard)
    """

    static func run(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") {
            print(usage)
            return 0
        }
        if arguments.contains("--apple-locales") {
            await printAppleLocales()
            return 0
        }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--transcribe") else {
            print(usage)
            return 2
        }
        let engineKind = value("--engine").flatMap(EngineKind.init(rawValue:)) ?? .whisperSmall
        let languageMode = value("--language").flatMap(LanguageMode.parse) ?? .default
        let store = DataStore()
        let vocabulary = arguments.contains("--no-vocabulary") ? [] : store.effectiveVocabulary
        let clipboard = value("--clipboard")

        do {
            let started = Date()
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            print("Audio: \(String(format: "%.1f", Double(samples.count) / 16_000)) s, engine: \(engineKind.rawValue), language: \(languageMode.title)")

            let engine = EngineFactory.make(engineKind)
            try await engine.prepare { status in print("  [model] \(status)") }
            let loaded = Date()
            print("Model ready in \(String(format: "%.1f", loaded.timeIntervalSince(started))) s")

            let transcription = try await engine.transcribe(samples: samples, language: languageMode, vocabulary: vocabulary)
            print("Transcribed in \(String(format: "%.1f", Date().timeIntervalSince(loaded))) s, language: \(transcription.detectedLanguage ?? "?")")
            if let info = transcription.debugInfo { print("  [lang] \(info)") }
            print("Raw:       \(transcription.text)")

            var text = VocabularyPostProcessor.apply(transcription.text, terms: store.vocabulary)
            let expansion = MacroExpander.stage1(text, macros: store.macros, clipboard: clipboard)
            text = expansion.text
            if expansion.clipboardWasEmpty { print("  [macro] clipboard was empty") }

            if let promptName = value("--prompt") {
                guard let prompt = store.prompts.first(where: { $0.name.caseInsensitiveCompare(promptName) == .orderedSame }) else {
                    print("Unknown prompt: \(promptName). Available: \(store.prompts.map(\.name).joined(separator: ", "))")
                    return 2
                }
                let instructions = PromptComposer.instructions(for: prompt, vocabulary: store.vocabulary, hasMacros: !expansion.usedMacroIDs.isEmpty)
                let processor: TextProcessor = prompt.provider == .shell
                    ? ShellCommandProcessor(commandTemplate: prompt.shellCommand)
                    : FoundationModelsProcessor()
                let aiStarted = Date()
                text = try await processor.process(text: text, instructions: instructions)
                print("AI (\(prompt.name), \(prompt.provider.rawValue)) in \(String(format: "%.1f", Date().timeIntervalSince(aiStarted))) s")
            }

            text = MacroExpander.stage2(text, macros: store.macros, clipboard: clipboard)
            print("Final:     \(text)")
            return 0
        } catch {
            print("Error: \(error.localizedDescription)")
            return 1
        }
    }
}

import Speech

extension DebugCLI {
    /// Prints Apple Speech locale support and asset status (for `--apple-locales`).
    static func printAppleLocales() async {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        print("Supported locales (\(supported.count)): \(supported.joined(separator: ", "))")
        let dictation = await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
        print("DictationTranscriber locales (\(dictation.count)): \(dictation.joined(separator: ", "))")
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        print("Installed locales: \(installed.joined(separator: ", "))")
        let reserved = await AssetInventory.reservedLocales.map(\.identifier)
        print("Reserved locales (max \(await AssetInventory.maximumReservedLocales)): \(reserved.joined(separator: ", "))")
        for id in ["pl-PL", "en-US"] {
            let locale = Locale(identifier: id)
            guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                print("\(id): not supported")
                continue
            }
            let transcriber = SpeechTranscriber(locale: match, preset: .transcription)
            let status = await AssetInventory.status(forModules: [transcriber])
            print("\(id) -> \(match.identifier): status \(status)")
        }
    }
}

/// Hosts the Settings view in a plain window at a fixed position (100,100 from bottom-left),
/// for screenshots: `--settings-demo`.
@MainActor
enum SettingsDemo {
    private static var window: NSWindow?
    private static var controller: DictationController?

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = DictationController()
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 620, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings (demo)"
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        app.activate(ignoringOtherApps: true)
        print("windowNumber=\(window.windowNumber)")
        app.run()
    }
}
