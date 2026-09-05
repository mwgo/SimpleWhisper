import Foundation
import AppKit

enum DictationError: LocalizedError {
    case tooShort
    case noSpeech
    case noSelection

    var errorDescription: String? {
        switch self {
        case .tooShort: return "Recording too short."
        case .noSpeech: return "No speech recognized."
        case .noSelection: return "No text selected and nothing dictated yet."
        }
    }
}

/// Orchestrates hotkey → recorder → engine → vocabulary → macros → AI → paste → HUD.
@MainActor
final class DictationController: HotkeyMonitorDelegate {
    let state = AppState()
    let settings = AppSettings()
    let store = DataStore()

    private let recorder = AudioRecorder()
    private let paster = TextPaster()
    private let hud = HUDWindowController()
    private let hotkey = HotkeyMonitor()
    private var engines: [EngineKind: SpeechEngine] = [:]
    private var pipelineTask: Task<Void, Never>?
    private var hotkeyRetryTask: Task<Void, Never>?
    private lazy var historyWindow = HistoryWindowController(
        store: store,
        onCopy: { [weak self] entry in self?.copyHistoryEntry(entry) },
        onPaste: { [weak self] entry in self?.pasteHistoryEntry(entry) }
    )
    private var capturedClipboard: String?
    /// Keeps the process out of App Nap while a dictation is in flight (otherwise the paste
    /// after a long AI step waits until the user clicks something).
    private var activityToken: NSObjectProtocol?

    init() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.setLevel(level) }
        }
        hud.promptsProvider = { [weak self] in self?.store.prompts ?? [] }
        hud.selectedPromptID = { [weak self] in self?.settings.selectedPromptID }
        hud.onRunCommand = { [weak self] in self?.stopAndRunCommand() }
        hud.onSelectPrompt = { [weak self] id in
            guard let self else { return }
            self.settings.selectedPromptID = id
            if case .recording = self.state.phase {
                self.hud.update(text: "Recording", detail: self.selectedPrompt?.name, stage: .recording)
            }
        }
    }

    var selectedPrompt: NamedPrompt? {
        guard let id = settings.selectedPromptID else { return nil }
        return store.prompts.first { $0.id == id }
    }

    // MARK: Lifecycle

    func start() {
        Task { _ = await Permissions.requestMicrophone() }
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
        if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }
        startHotkey()
        Task { await loadModel() }
    }

    func startHotkey() {
        hotkey.delegate = self
        hotkey.holdThreshold = Double(settings.holdThresholdMs) / 1000
        do {
            try hotkey.start()
            state.hotkeyError = nil
            hotkeyRetryTask?.cancel()
            hotkeyRetryTask = nil
        } catch {
            state.hotkeyError = error.localizedDescription
            scheduleHotkeyRetry()
        }
    }

    /// The event tap can only be created once Accessibility/Input Monitoring is granted;
    /// keep retrying so the user does not have to relaunch after clicking through System Settings.
    private func scheduleHotkeyRetry() {
        guard hotkeyRetryTask == nil else { return }
        hotkeyRetryTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.hotkey.isRunning {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                self.hotkeyRetryTask = nil
                self.startHotkey()
                if self.hotkey.isRunning { return }
                if self.hotkeyRetryTask != nil { return }
            }
        }
    }

    var isHotkeyRunning: Bool { hotkey.isRunning }

    // MARK: Model loading

    func loadModel() async {
        let kind = settings.engineKind
        do {
            _ = try await ensureEngine(kind)
        } catch {
            state.modelStatus = "Failed: \(error.localizedDescription)"
        }
    }

    private func ensureEngine(_ kind: EngineKind) async throws -> SpeechEngine {
        let engine = engines[kind] ?? EngineFactory.make(kind)
        engines[kind] = engine
        if engine.isReady {
            state.modelStatus = "\(kind.title) ready"
            return engine
        }
        state.isModelLoading = true
        state.modelStatus = "Loading \(kind.title)…"
        defer { state.isModelLoading = false }
        try await engine.prepare { [weak self] status in
            Task { @MainActor in
                self?.state.modelStatus = status
                if let self, self.state.phase == .transcribing {
                    self.hud.update(text: status, stage: .transcribing)
                }
            }
        }
        state.modelStatus = "\(kind.title) ready"
        return engine
    }

    // MARK: Hotkey delegate

    var isDictationActive: Bool { state.phase.isActive }

    func hotkeyToggle() {
        switch state.phase {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        default: break
        }
    }

    func hotkeyPushToTalkStart() {
        if state.phase == .idle { startRecording() }
    }

    func hotkeyPushToTalkStop() {
        if state.phase == .recording { stopAndTranscribe() }
    }

    func hotkeyCancel() {
        cancel()
    }

    // MARK: Dictation

    func toggleDictation() { hotkeyToggle() }

    func startRecording() {
        guard state.phase == .idle else { return }
        state.lastError = nil
        capturedClipboard = NSPasteboard.general.string(forType: .string)
        paster.rememberTarget()
        do {
            try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        state.phase = .recording
        beginActivity()
        hud.placement = settings.hudPlacement
        hud.showsText = settings.hudShowsText
        hud.show(text: "Recording", detail: selectedPrompt?.name, stage: .recording, commandButton: settings.commandModeEnabled)
        state.hudAnchor = hud.anchorDescription
        DebugLog.write("HUD \(hud.anchorDebug ?? "-")")
        if engines[settings.engineKind]?.isReady != true {
            Task { await loadModel() }
        }
    }

    func stopAndTranscribe() {
        guard state.phase == .recording else { return }
        let samples = recorder.stop()
        state.phase = .transcribing
        hud.update(text: "Transcribing…", stage: .transcribing)
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(samples: samples)
        }
    }

    /// Command mode: the recording is an instruction to apply (via AI) to the text selected in the editor.
    func stopAndRunCommand() {
        guard state.phase == .recording, settings.commandModeEnabled else { return }
        let samples = recorder.stop()
        state.phase = .transcribing
        hud.update(text: "Reading selection…", stage: .transcribing)
        pipelineTask = Task { [weak self] in
            await self?.runCommandPipeline(samples: samples)
        }
    }

    private func runCommandPipeline(samples: [Float]) async {
        do {
            guard samples.count >= Int(AudioRecorder.targetFormat.sampleRate) / 3 else { throw DictationError.tooShort }
            var selection = await SelectionReader.selectedText(in: paster.targetApplication)
            try Task.checkCancellation()
            // No selection: the command refers to the text that was just pasted; select it so the result replaces it.
            var usesLastPaste = false
            let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // Some editors (VS Code) copy the whole line when nothing is selected; if that equals the
            // last paste, treat it as "no selection" so the previous text gets replaced.
            if let current = selection, !state.lastText.isEmpty, normalize(current) == normalize(state.lastText) {
                selection = nil
            }
            if selection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                guard !state.lastText.isEmpty else { throw DictationError.noSelection }
                selection = state.lastText
                usesLastPaste = true
            }
            guard let selection else { throw DictationError.noSelection }
            hud.update(text: "Transcribing command…", stage: .transcribing)
            let engine = try await ensureEngine(settings.engineKind)
            try Task.checkCancellation()
            let vocabulary = store.effectiveVocabulary(spokenPunctuation: false)
            let transcription = try await engine.transcribe(samples: samples, language: settings.languageMode, vocabulary: vocabulary)
            try Task.checkCancellation()
            let instruction = VocabularyPostProcessor.apply(transcription.text, terms: store.vocabulary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { throw DictationError.noSpeech }
            DebugLog.write("Command: \"\(instruction)\" on \(selection.count) chars")

            let preview = instruction.count > 40 ? String(instruction.prefix(40)) + "…" : instruction
            state.phase = .processing("Command")
            hud.update(text: "Command", detail: preview, stage: .processing)
            let ticker = Task { [weak self] in
                var seconds = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    seconds += 1
                    self?.hud.update(text: "Command", detail: "\(preview) · \(seconds)s", stage: .processing)
                }
            }
            defer { ticker.cancel() }
            let processor = ShellCommandProcessor(commandTemplate: settings.commandShellCommand)
            let result: String
            do {
                result = try await processor.process(text: selection, instructions: CommandComposer.instructions(spoken: instruction, vocabulary: store.vocabulary))
            }
            ticker.cancel()   // otherwise a late tick would re-show the HUD after hide()
            try Task.checkCancellation()

            state.lastText = result
            state.lastLanguage = transcription.detectedLanguage
            state.phase = .idle
            recordHistory(HistoryEntry(date: Date(), kind: .command, text: result, instruction: instruction, language: transcription.detectedLanguage))
            hud.hide()
            if usesLastPaste {
                let selected = await SelectionReader.selectBackwards(expected: selection, in: paster.targetApplication)
                DebugLog.write("Command: re-selected last paste (\(selection.count) chars) = \(selected)")
                if !selected {
                    hud.flash("Could not re-select the previous text; result appended", duration: .seconds(2.5))
                }
            }
            await paster.paste(result, keepInClipboard: settings.keepTextInClipboard)
            endActivity()
        } catch is CancellationError {
            if state.phase != .idle {
                state.phase = .idle
                endActivity()
                hud.hide()
            }
        } catch {
            DebugLog.write("Command error: \(error)")
            showError(error.localizedDescription)
        }
    }

    private func recordHistory(_ entry: HistoryEntry) {
        guard settings.historyEnabled else { return }
        store.addHistory(entry)
    }

    func showHistory() {
        historyWindow.show()
    }

    /// Pastes the entry's text into the frontmost editor (the history panel never takes focus).
    func pasteHistoryEntry(_ entry: HistoryEntry) {
        paster.rememberTarget()
        Task { [weak self] in
            guard let self else { return }
            await self.paster.paste(entry.text, keepInClipboard: self.settings.keepTextInClipboard)
        }
    }

    /// Puts the entry's text on the clipboard and confirms in the HUD.
    func copyHistoryEntry(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        hud.flash("Copied to clipboard", duration: .seconds(1.5))
    }

    func cancel() {
        DebugLog.write("cancel() called in phase \(state.phase)")
        switch state.phase {
        case .idle:
            return
        case .recording:
            _ = recorder.stop()
        case .transcribing, .processing:
            pipelineTask?.cancel()
        }
        pipelineTask = nil
        state.phase = .idle
        endActivity()
        hud.flash("Cancelled")
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Dictation in progress"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        activityToken = nil
    }

    private func runPipeline(samples: [Float]) async {
        do {
            guard samples.count >= Int(AudioRecorder.targetFormat.sampleRate) / 3 else { throw DictationError.tooShort }
            let engine = try await ensureEngine(settings.engineKind)
            try Task.checkCancellation()
            hud.update(text: "Transcribing…", stage: .transcribing)

            let vocabulary = store.effectiveVocabulary(spokenPunctuation: settings.spokenPunctuationEnabled)
            let macros = store.activeMacros(spokenPunctuation: settings.spokenPunctuationEnabled)
            let transcription = try await engine.transcribe(samples: samples, language: settings.languageMode, vocabulary: vocabulary)
            try Task.checkCancellation()

            var text = VocabularyPostProcessor.apply(transcription.text, terms: store.vocabulary)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationError.noSpeech }

            let expansion = MacroExpander.stage1(text, macros: macros, clipboard: capturedClipboard)
            text = expansion.text
            let languageLabel = transcription.detectedLanguage?.uppercased()

            if let prompt = selectedPrompt {
                state.phase = .processing(prompt.name)
                hud.update(text: "Processing", detail: [languageLabel, prompt.name].compactMap { $0 }.joined(separator: " · "), stage: .processing)
                let instructions = PromptComposer.instructions(for: prompt, vocabulary: store.vocabulary, hasMacros: !expansion.usedMacroIDs.isEmpty)
                let detailBase = [languageLabel, prompt.name].compactMap { $0 }.joined(separator: " · ")
                let ticker = Task { [weak self] in
                    var seconds = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        seconds += 1
                        self?.hud.update(text: "Processing", detail: "\(detailBase) · \(seconds)s", stage: .processing)
                    }
                }
                defer { ticker.cancel() }
                do {
                    text = try await makeProcessor(for: prompt).process(text: text, instructions: instructions)
                    ticker.cancel()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    ticker.cancel()
                    state.lastError = error.localizedDescription
                    DebugLog.write("AI failed (\(prompt.name), \(prompt.provider.rawValue), cmd=\(prompt.shellCommand)): \(error)")
                    hud.update(text: "AI failed, pasting raw text", stage: .message)
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if Task.isCancelled && state.phase == .idle { return }
            }

            text = MacroExpander.stage2(text, macros: macros, clipboard: capturedClipboard)
            state.lastText = text
            state.lastLanguage = transcription.detectedLanguage
            state.phase = .idle
            recordHistory(HistoryEntry(date: Date(), kind: .dictation, text: text, language: transcription.detectedLanguage))

            if expansion.clipboardWasEmpty {
                hud.flash("Clipboard was empty", duration: .seconds(2))
            } else {
                hud.hide()
            }
            await paster.paste(text, keepInClipboard: settings.keepTextInClipboard)
            endActivity()
        } catch is CancellationError {
            if state.phase != .idle {
                DebugLog.write("Pipeline cancelled unexpectedly in phase \(state.phase)")
                state.phase = .idle
                endActivity()
                hud.hide()
            }
        } catch {
            DebugLog.write("Pipeline error: \(error)")
            showError(error.localizedDescription)
        }
    }

    private func makeProcessor(for prompt: NamedPrompt) -> TextProcessor {
        switch prompt.provider {
        case .appleFoundationModels:
            return FoundationModelsProcessor()
        case .shell:
            let template = prompt.shellCommand.trimmingCharacters(in: .whitespaces)
            return ShellCommandProcessor(commandTemplate: template.isEmpty ? settings.defaultShellCommand : template)
        }
    }

    private func showError(_ message: String) {
        DebugLog.write("Error: \(message)")
        endActivity()
        state.lastError = message
        state.phase = .idle
        hud.flash("Error: \(message)", duration: .seconds(3))
    }
}


/// Appends diagnostics to ~/Library/Application Support/SimpleWhisper/debug.log.
enum DebugLog {
    static func write(_ message: String) {
        let url = DataStore.directory.appendingPathComponent("debug.log")
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
