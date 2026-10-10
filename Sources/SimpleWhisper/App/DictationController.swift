import Foundation
import AppKit
import AVFoundation

enum DictationError: LocalizedError {
    case tooShort
    case noSpeech
    case noSelection

    var errorDescription: String? {
        switch self {
        case .tooShort: return "Recording too short."
        case .noSpeech: return "No speech recognized."
        case .noSelection: return "No text selected in the editor."
        }
    }
}

/// Orchestrates hotkey → recorder → engine → vocabulary → macros → AI → paste → HUD.
@MainActor
final class DictationController: HotkeyMonitorDelegate {
    let state = AppState()
    let settings = AppSettings()
    let store = DataStore()
    private(set) lazy var updater = Updater(settings: settings)
    private var lastRecordingStart = Date.distantPast

    private let recorder = AudioRecorder()
    private let paster = TextPaster()
    private let hud = HUDWindowController()
    private let resultWindow = ResultWindowController()
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
    /// Whether a text field had focus when recording started (decides paste vs. result window).
    private var pasteTargetAvailable = true
    /// Keeps the process out of App Nap while a dictation is in flight (otherwise the paste
    /// after a long AI step waits until the user clicks something).
    private var activityToken: NSObjectProtocol?
    // Live typing session state.
    private let liveEditor = LiveEditorController()
    private var liveSession = false
    /// Tail of the serial chunk-transcription chain (engines must not run concurrently).
    private var liveQueue: Task<Void, Never>?
    /// Bumped on every new session or cancel so late chunk results are ignored.
    private var liveGeneration = 0
    private var liveLanguage: String?
    /// Placeholder of the utterance being spoken now (shows the provisional preview).
    private var liveActiveID: String?
    private var livePendingFinals = 0
    private var livePreviewBusy = false
    private var livePreviewLoop: Task<Void, Never>?
    /// Latest preview per placeholder: a final result never replaces a longer preview.
    private var livePreviews: [String: (raw: String, text: String)] = [:]
    /// Live typing goes through the SimpleWhisper input method: the dictation is marked text in the app.
    private let inputSource = InputSourceBridge()
    private var imeSession = false
    /// The app the input method session types into; the dictation never follows focus to another app.
    private var imeApp: NSRunningApplication?
    /// Bumped whenever the user commits the marked text in the app (typing, clicking, switching apps).
    private var imeCommits = 0
    /// Finished utterances already inserted in the app during this dictation.
    private var imeDelivered = ""
    /// The dictation was finished with Return: press it in the app once the text is in.
    private var returnAfterDelivery = false
    private var contextRefresh: Task<Void, Never>?

    init() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.setLevel(level) }
        }
        liveEditor.onUserEdit = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.closeActiveUtterance() } }
        }
        liveEditor.onContentChange = { [weak self] in
            guard let self, self.imeSession else { return }
            self.inputSource.mark(self.liveEditor.shownDictation)
        }
        inputSource.onCommitted = { [weak self] in self?.inputMethodCommitted() }
        inputSource.onInput = { [weak self] in self?.scheduleContextRefresh() }
        InputSourceBridge.updateInstalledCopy()
        recorder.onSegmentsAvailable = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drainLiveSegments() } }
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
        updater.isIdle = { [weak self] in
            guard let self else { return true }
            return self.state.phase == .idle && Date().timeIntervalSince(self.lastRecordingStart) > 60
        }
        updater.willRelaunch = { [weak self] version in self?.hud.flash("Updating to \(version)…", duration: .seconds(2)) }
        updater.start()
    }

    /// Menu bar "Check for Updates…": checks now and reports the result in an alert.
    func checkForUpdatesInteractively() {
        Task {
            await updater.check(install: settings.autoUpdateEnabled)
            let alert = NSAlert()
            alert.messageText = "SimpleWhisper \(Updater.currentVersion)"
            alert.informativeText = updater.status
            alert.addButton(withTitle: "OK")
            if updater.availableVersion != nil, updater.releasePage != nil { alert.addButton(withTitle: "Open Release Page") }
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn, let page = updater.releasePage {
                NSWorkspace.shared.open(page)
            }
        }
    }

    func startHotkey() {
        hotkey.delegate = self
        applyHotkeySettings()
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

    /// Applies hotkey-related settings without recreating the event tap.
    func applyHotkeySettings() {
        hotkey.triggerKey = settings.hotkeyKey
        hotkey.holdThreshold = Double(settings.holdThresholdMs) / 1000
        hotkey.doublePressMode = settings.fnDoublePress
        hotkey.doublePressWindow = Double(settings.doublePressWindowMs) / 1000
        hotkey.polishLetters = settings.polishRightCommand
    }

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

    var isLiveEditing: Bool { liveSession && state.phase.isActive }

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

    func hotkeyPromptShortcut(_ character: String) -> Bool {
        guard state.phase == .recording else { return false }
        if character == " " {
            settings.selectedPromptID = nil
            hud.update(text: "Recording", detail: nil, stage: .recording)
            return true
        }
        let key = character.lowercased()
        guard let prompt = store.prompts.first(where: { $0.shortcut.lowercased() == key && !$0.shortcut.isEmpty }) else { return false }
        settings.selectedPromptID = prompt.id
        hud.update(text: "Recording", detail: prompt.name, stage: .recording)
        return true
    }

    func hotkeyReturn() -> Bool {
        guard settings.returnFinishesDictation else { return false }
        switch state.phase {
        case .idle:
            return false
        case .recording:
            returnAfterDelivery = true
            stopAndTranscribe()
        case .transcribing, .processing:
            returnAfterDelivery = true
        }
        return true
    }

    func hotkeyReturnInInputMethod(flags: CGEventFlags) -> Bool {
        guard imeSession, liveSession, state.phase == .recording else { return false }
        // Chromium apps drop the composition when it is committed while they handle the same key.
        Task { [inputSource] in
            _ = await inputSource.flush()
            HotkeyMonitor.pressReturn(flags: flags)
        }
        return true
    }

    /// Presses Return in the app after the text went in; nothing when it was shown in a window instead.
    private func pressReturnIfRequested(inserted: Bool) async {
        guard returnAfterDelivery else { return }
        returnAfterDelivery = false
        guard inserted else { return }
        try? await Task.sleep(for: .milliseconds(150))
        HotkeyMonitor.pressReturn()
    }

    func hotkeyCancelSilently() {
        guard state.phase == .recording else { return }
        _ = recorder.stop()
        pipelineTask = nil
        state.phase = .idle
        endActivity()
        hud.hide(animated: false)
        DebugLog.write("Recording cancelled silently (key pressed right after fn)")
    }

    func hotkeyRunCommand() -> Bool {
        guard state.phase == .recording, settings.commandModeEnabled, !liveSession else { return false }
        stopAndRunCommand()
        return true
    }

    // MARK: Dictation

    func toggleDictation() { hotkeyToggle() }

    func startRecording() {
        guard state.phase == .idle else { return }
        lastRecordingStart = Date()
        state.lastError = nil
        capturedClipboard = NSPasteboard.general.string(forType: .string)
        paster.rememberTarget()
        pasteTargetAvailable = PasteTargetProbe.canPasteIntoFocusedElement()
        liveSession = settings.liveTypingEnabled
        returnAfterDelivery = false
        imeSession = false
        imeDelivered = ""
        let throughInputMethod = liveSession && InputSourceBridge.status == .selected
        recorder.segmentsEnabled = liveSession
        if liveSession {
            liveGeneration += 1
            liveQueue = nil
            liveLanguage = nil
            liveActiveID = nil
            livePreviews = [:]
            livePendingFinals = 0
            livePreviewBusy = false
            liveEditor.reset()
            LiveEditorController.properNouns = Set(store.vocabulary.flatMap { $0.text.split(separator: " ").map(String.init) }.filter { $0.first?.isUppercase == true })
        }
        do {
            try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        state.phase = .recording
        beginActivity()
        if settings.soundsEnabled { SoundPlayer.recordingStarted() }
        hud.placement = settings.hudPlacement
        hud.showsText = settings.hudShowsText
        hud.theme = settings.hudTheme
        hud.glass = settings.hudGlass
        hud.show(text: "Recording", detail: selectedPrompt?.name, stage: .recording,
                 commandButton: settings.commandModeEnabled && !liveSession,
                 liveEditor: liveSession && !throughInputMethod ? liveEditor : nil)
        state.hudAnchor = hud.anchorDescription
        DebugLog.write("HUD \(hud.anchorDebug ?? "-")")
        if engines[settings.engineKind]?.isReady != true {
            Task { await loadModel() }
        }
        if throughInputMethod { connectInputMethod() }
        if liveSession { startLivePreviewLoop() }
    }

    func stopAndTranscribe() {
        guard state.phase == .recording else { return }
        if liveSession {
            stopLiveTyping()
            return
        }
        let samples = recorder.stop()
        if settings.soundsEnabled { SoundPlayer.recordingStopped() }
        state.phase = .transcribing
        hud.update(text: "Transcribing…", stage: .transcribing)
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(samples: samples)
        }
    }

    /// Command mode: the recording is an instruction to apply (via AI) to the text selected in the editor.
    func stopAndRunCommand() {
        guard state.phase == .recording, settings.commandModeEnabled, !liveSession else { return }
        let samples = recorder.stop()
        if settings.soundsEnabled { SoundPlayer.recordingStopped() }
        state.phase = .transcribing
        hud.update(text: "Reading selection…", stage: .transcribing)
        pipelineTask = Task { [weak self] in
            await self?.runCommandPipeline(samples: samples)
        }
    }

    /// Keeps the most recent recording as `last-recording.wav` in the data folder so a bad
    /// transcription can be reproduced with `--transcribe`.
    private static func saveLastRecording(_ samples: [Float]) {
        let url = DataStore.directory.appendingPathComponent("last-recording.wav")
        do {
            let buffer = try AudioConversion.buffer(from: samples, to: AudioRecorder.targetFormat)
            let file = try AVAudioFile(forWriting: url, settings: AudioRecorder.targetFormat.settings)
            try file.write(from: buffer)
        } catch {
            DebugLog.write("Could not save last recording: \(error.localizedDescription)")
        }
    }

    private func runCommandPipeline(samples: [Float]) async {
        do {
            guard samples.count >= Int(AudioRecorder.targetFormat.sampleRate) / 3 else { throw DictationError.tooShort }
            Self.saveLastRecording(samples)
            var selection = await SelectionReader.selectedText(in: paster.targetApplication)
            try Task.checkCancellation()
            // Some editors (VS Code) copy the whole line when nothing is selected; if that equals the
            // last paste, treat it as "no selection".
            let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let current = selection, !state.lastText.isEmpty, normalize(current) == normalize(state.lastText) {
                selection = nil
            }
            // No selection: treat the dictation as a direct question to the assistant, answer shown as Markdown.
            let isAssistant = selection.map { normalize($0).isEmpty } ?? true
            if isAssistant { selection = nil }
            hud.update(text: "Transcribing command…", stage: .transcribing)
            let engine = try await ensureEngine(settings.engineKind)
            try Task.checkCancellation()
            let vocabulary = store.effectiveVocabulary(spokenPunctuation: false)
            guard let transcription = try await transcribe(engine, samples, vocabulary: vocabulary) else { throw DictationError.noSpeech }
            try Task.checkCancellation()
            let instruction = VocabularyPostProcessor.apply(transcription.text, terms: store.vocabulary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { throw DictationError.noSpeech }
            DebugLog.write("Command: \"\(instruction)\" on \(selection?.count ?? 0) chars")

            let preview = instruction.count > 40 ? String(instruction.prefix(40)) + "…" : instruction
            let label = isAssistant ? "Assistant" : "Command"
            state.phase = .processing(label)
            hud.update(text: label, detail: preview, stage: .processing)
            let ticker = Task { [weak self] in
                var seconds = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    seconds += 1
                    self?.hud.update(text: label, detail: "\(preview) · \(seconds)s", stage: .processing)
                }
            }
            defer { ticker.cancel() }
            let processor = AIProviderFactory.makeProcessor(provider: settings.commandProvider, shellTemplate: "", settings: settings, context: .command)
            let result: String
            if let selection {
                result = try await processor.process(text: selection, instructions: CommandComposer.instructions(spoken: instruction, vocabulary: store.vocabulary, wantMarkdown: wantsMarkdown))
            } else {
                result = try await processor.process(text: instruction, instructions: AssistantComposer.instructions(vocabulary: store.vocabulary))
            }
            ticker.cancel()   // otherwise a late tick would re-show the HUD after hide()
            try Task.checkCancellation()

            state.lastText = result
            state.lastLanguage = transcription.detectedLanguage
            state.phase = .idle
            recordHistory(HistoryEntry(date: Date(), kind: .command, text: result, instruction: instruction, language: transcription.detectedLanguage))
            if isAssistant {
                hud.hide()
                resultWindow.show(text: result)
            } else {
                await deliver(result)
            }
            endActivity()
        } catch is CancellationError {
            if state.phase != .idle {
                state.phase = .idle
                endActivity()
                hud.hide()
            }
        } catch let error as DictationError where error == .noSpeech || error == .tooShort {
            dismissQuietly(reason: error)
        } catch {
            DebugLog.write("Command error: \(error)")
            showError(error.localizedDescription)
        }
    }

    /// AI output should be Markdown when it will be shown in the result window instead of pasted.
    private var wantsMarkdown: Bool { !pasteTargetAvailable && settings.markdownWhenNotPasting }

    /// Pastes into the active text field, or, when nothing can accept a paste, shows the text in a window
    /// (rendered as Markdown when it looks like Markdown). The clipboard is left alone.
    /// Hides the HUD (or flashes `notice`) and pastes; when there is nothing to paste into, the HUD
    /// becomes the result card instead, so it must not be hidden first.
    /// Returns true when the text was pasted into the app (false: shown in a window).
    @discardableResult
    private func deliver(_ text: String, canPaste: Bool? = nil, animatedHide: Bool = true, notice: String? = nil) async -> Bool {
        if canPaste ?? PasteTargetProbe.canPasteIntoFocusedElement() {
            if let notice {
                hud.flash(notice, duration: .seconds(2))
            } else {
                hud.hide(animated: animatedHide)
            }
            await paster.paste(text, keepInClipboard: settings.keepTextInClipboard)
            return true
        } else if MarkdownRenderer.looksLikeMarkdown(text) {
            DebugLog.write("No editable field focused; showing Markdown result window")
            hud.hide()
            resultWindow.show(text: text)
        } else {
            DebugLog.write("No editable field focused; showing the result card")
            hud.showResult(text, editor: liveEditor)
        }
        return false
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
            await self?.deliver(entry.text)
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
        returnAfterDelivery = false
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
        if settings.soundsEnabled { SoundPlayer.recordingCancelled() }
        if liveSession {
            let throughInputMethod = imeSession
            endLiveSession()
            let text = throughInputMethod ? (imeDelivered + liveEditor.dictation).trimmingCharacters(in: .whitespacesAndNewlines) : liveEditor.text
            if throughInputMethod { Task { [inputSource] in _ = await inputSource.insert("") } }
            if !text.isEmpty {
                recordHistory(HistoryEntry(date: Date(), kind: .dictation, text: text, language: liveLanguage))
            }
            hud.hide(reverse: true)
            return
        }
        hud.flash("Cancelled", reverseDismiss: true)
    }

    // MARK: Live typing

    private func endLiveSession() {
        liveGeneration += 1
        liveQueue?.cancel()
        liveQueue = nil
        livePreviewLoop?.cancel()
        livePreviewLoop = nil
        liveActiveID = nil
        liveSession = false
        if imeSession { inputSource.setSessionActive(false) }
        imeSession = false
        contextRefresh?.cancel()
        recorder.segmentsEnabled = false
    }

    private func drainLiveSegments() {
        guard liveSession, state.phase == .recording else { return }
        for range in recorder.takeSegments() {
            enqueueLiveChunk(recorder.samples(in: range))
        }
    }

    /// Commits a finished utterance: its placeholder (the one showing the preview, or a new one at the
    /// caret) is filled with the final transcription.
    private func enqueueLiveChunk(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let id = liveActiveID ?? liveEditor.insertPlaceholder()
        liveActiveID = nil
        livePendingFinals += 1
        let generation = liveGeneration
        let previous = liveQueue
        liveQueue = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.liveGeneration else { return }
            await self.transcribeLiveChunk(samples, placeholder: id, generation: generation, final: true)
            self.livePendingFinals -= 1
        }
    }

    /// The user clicked, moved the caret or typed: whatever is being said now belongs to the old spot,
    /// and the next words start a new utterance at the new caret.
    private func closeActiveUtterance() {
        guard liveSession, state.phase == .recording else { return }
        drainLiveSegments()
        // Nothing shown yet: the words being spoken simply land at the new caret.
        guard let id = liveActiveID else { return }
        if let samples = recorder.cutOpenSegment() {
            enqueueLiveChunk(samples)   // commits into the active placeholder
        } else {
            liveActiveID = nil
            liveEditor.drop(id)
        }
    }

    /// Every 0.4 s (when the previous one has finished), re-transcribes the utterance in progress and shows it greyed in the editor.
    private func startLivePreviewLoop() {
        livePreviewLoop?.cancel()
        livePreviewLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, self.liveSession, self.state.phase == .recording else { return }
                self.schedulePreview()
            }
        }
    }

    private func schedulePreview() {
        // Cloud engines would be billed for every preview; finished utterances only.
        guard settings.engineKind != .geminiAPI, livePendingFinals == 0, !livePreviewBusy else { return }
        let open = recorder.openSegment()
        guard open.hasSpeech, open.range.count >= 8_000 else { return }
        let samples = recorder.samples(in: open.range)
        let id = liveActiveID ?? liveEditor.insertPlaceholder()
        liveActiveID = id
        livePreviewBusy = true
        let generation = liveGeneration
        let previous = liveQueue
        liveQueue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.livePreviewBusy = false }
            guard generation == self.liveGeneration else { return }
            await self.transcribeLiveChunk(samples, placeholder: id, generation: generation, final: false)
        }
    }

    private func transcribeLiveChunk(_ samples: [Float], placeholder id: String, generation: Int, final: Bool) async {
        do {
            let engine = try await ensureEngine(settings.engineKind)
            let vocabulary = store.effectiveVocabulary(spokenPunctuation: settings.spokenPunctuationEnabled)
            let macros = store.activeMacros(spokenPunctuation: settings.spokenPunctuationEnabled)
            let transcription = try await transcribe(engine, samples, vocabulary: vocabulary)
            guard generation == liveGeneration else { return }
            if transcription == nil && !final { return }
            // Lengths are compared before spoken punctuation turns "przecinek" into ",".
            let raw = VocabularyPostProcessor.apply(transcription?.text ?? "", terms: store.vocabulary)
            var text = MacroExpander.stage1(raw, macros: macros, clipboard: capturedClipboard).text
            let spokenEnding = text.trimmingCharacters(in: .whitespaces).hasSuffix("⟧")
            text = MacroExpander.stage2(text, macros: macros, clipboard: capturedClipboard, leadingPunctuation: true)
            guard final else {
                // Ignore a preview that suddenly lost most of its text (a decoder hiccup).
                if raw.count >= Int(Double(livePreviews[id]?.raw.count ?? 0) * 0.7) {
                    livePreviews[id] = (raw, text)
                    liveEditor.preview(id, with: text)
                }
                return
            }
            if let preview = livePreviews.removeValue(forKey: id), Double(raw.count) < Double(preview.raw.count) * 0.6 {
                DebugLog.write("Live chunk final (\(raw.count) chars) shorter than its preview (\(preview.raw.count)); keeping the preview")
                text = preview.text
            }
            liveLanguage = transcription?.detectedLanguage ?? liveLanguage
            DebugLog.write("Live chunk \(String(format: "%.1f", Double(samples.count) / 16_000)) s → \(text.count) chars")
            liveEditor.resolve(id, with: text, spokenEnding: spokenEnding, language: transcription?.detectedLanguage)
            commitFinishedText()
        } catch {
            guard generation == liveGeneration, final else { return }
            DebugLog.write("Live chunk failed: \(error)")
            liveEditor.drop(id)
        }
    }

    private func stopLiveTyping() {
        livePreviewLoop?.cancel()
        livePreviewLoop = nil
        let (samples, segments) = recorder.stopWithSegments()
        if settings.soundsEnabled { SoundPlayer.recordingStopped() }
        state.phase = .transcribing
        hud.update(text: "Transcribing…", detail: selectedPrompt?.name, stage: .transcribing)
        for range in segments {
            enqueueLiveChunk(Array(samples[range.clamped(to: 0..<samples.count)]))
        }
        if let orphan = liveActiveID {
            // A preview whose utterance turned out to be noise: remove it once pending work is done.
            liveActiveID = nil
            let previous = liveQueue
            liveQueue = Task { [weak self] in
                await previous?.value
                self?.liveEditor.drop(orphan)
            }
        }
        let pending = liveQueue
        pipelineTask = Task { [weak self] in
            await pending?.value
            await self?.finishLiveTyping(samples: samples)
        }
    }

    private func finishLiveTyping(samples: [Float]) async {
        guard !Task.isCancelled, liveSession, state.phase != .idle else { return }
        if !samples.isEmpty { Self.saveLastRecording(samples) }
        let throughInputMethod = imeSession
        let dictated = throughInputMethod ? liveEditor.dictation : liveEditor.text
        // With the input method the spaces next to the existing text are already fitted; keep them.
        let leading = String(dictated.prefix { $0.isWhitespace })
        let trailing = String(dictated.reversed().prefix { $0.isWhitespace }.reversed())
        var text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivered = imeDelivered
        guard !text.isEmpty else {
            endLiveSession()
            if throughInputMethod { _ = await inputSource.insert("") }
            if delivered.isEmpty {
                dismissQuietly(reason: .noSpeech)
            } else {
                finishDelivered(delivered.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            await pressReturnIfRequested(inserted: true)
            return
        }
        let commits = imeCommits
        do {
            if let prompt = selectedPrompt {
                liveEditor.textView.isEditable = false
                text = try await applyPrompt(prompt, to: text, languageLabel: liveLanguage?.uppercased(), hasMacros: false)
            }
        } catch {
            return   // cancelled; cancel() already cleaned up
        }
        guard state.phase != .idle else { return }
        endLiveSession()
        let whole = (delivered + leading + text).trimmingCharacters(in: .whitespacesAndNewlines)
        state.lastText = whole
        state.lastLanguage = liveLanguage
        state.phase = .idle
        recordHistory(HistoryEntry(date: Date(), kind: .dictation, text: whole, language: liveLanguage))
        var inserted = true
        if throughInputMethod {
            hud.hide(animated: false)
            if imeCommits != commits {
                DebugLog.write("Marked text was committed in the app while the prompt ran; not inserting the result")
                inserted = false
            } else if !(await inputSource.insert(leading + text + trailing)) {
                DebugLog.write("Input method did not confirm the insert; delivering the usual way")
                inserted = await deliver(text, animatedHide: false)
            }
        } else {
            inserted = await deliver(text, canPaste: pasteTargetAvailable, animatedHide: false)
        }
        endActivity()
        await pressReturnIfRequested(inserted: inserted)
    }

    /// Everything was already inserted in the app utterance by utterance.
    private func finishDelivered(_ text: String) {
        state.lastText = text
        state.lastLanguage = liveLanguage
        state.phase = .idle
        recordHistory(HistoryEntry(date: Date(), kind: .dictation, text: text, language: liveLanguage))
        hud.hide(animated: false)
        endActivity()
    }

    // MARK: Input method

    /// Through the input method, finished utterances go into the app as plain text and only the one in
    /// progress stays marked. With a prompt selected everything stays marked, so the prompt sees all of it.
    private func commitFinishedText() {
        guard imeSession, state.phase == .recording, selectedPrompt == nil else { return }
        let finished = liveEditor.takeFinished()
        guard !finished.isEmpty else { return }
        imeDelivered += finished
        inputSource.commit(finished, keepingMarked: liveEditor.shownDictation)
        DebugLog.write("Input method: inserted a finished utterance (\(finished.count) chars)")
    }

    /// Asks the input method for the focused field of the app being dictated into; without an answer
    /// the session falls back to the HUD editor.
    private func connectInputMethod() {
        let generation = liveGeneration
        let app = NSWorkspace.shared.frontmostApplication
        imeApp = app
        Task { [weak self] in
            guard let self else { return }
            let before = await self.inputSource.connect(to: app)
            guard generation == self.liveGeneration, self.liveSession, self.state.phase == .recording else { return }
            if let context = before {
                self.liveEditor.seedContext(before: context.before, after: context.after)
                self.imeSession = true
                self.inputSource.setSessionActive(true)
                DebugLog.write("Live typing through the input method in \(app?.bundleIdentifier ?? "?") (context \(context.before.count) + \(context.after.count) chars)")
            } else {
                DebugLog.write("Input method did not answer; Live typing in the HUD editor")
                self.hud.show(text: "Recording", detail: self.selectedPrompt?.name, stage: .recording, liveEditor: self.liveEditor)
            }
        }
    }

    /// The user typed, clicked or switched apps: the marked text stays where it is, and the dictation
    /// continues at the new caret.
    private func inputMethodCommitted() {
        guard imeSession, liveSession else { return }
        imeCommits += 1
        if state.phase == .recording { closeActiveUtterance() }
        liveEditor.freeze()
        scheduleContextRefresh()
    }

    /// Re-reads the text around the caret once the app has taken the user's keys or click.
    private func scheduleContextRefresh() {
        guard imeSession, liveSession else { return }
        let generation = liveGeneration
        contextRefresh?.cancel()
        contextRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, generation == self.liveGeneration,
                  let app = self.imeApp, NSWorkspace.shared.frontmostApplication == app,
                  let context = await self.inputSource.connect(to: app),
                  generation == self.liveGeneration else { return }
            self.liveEditor.seedContext(before: context.before, after: context.after)
            DebugLog.write("Input method: context at the caret \(context.before.count) + \(context.after.count) chars")
        }
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
            Self.saveLastRecording(samples)
            let engine = try await ensureEngine(settings.engineKind)
            try Task.checkCancellation()
            hud.update(text: "Transcribing…", stage: .transcribing)

            let vocabulary = store.effectiveVocabulary(spokenPunctuation: settings.spokenPunctuationEnabled)
            let macros = store.activeMacros(spokenPunctuation: settings.spokenPunctuationEnabled)
            guard let transcription = try await transcribe(engine, samples, vocabulary: vocabulary) else { throw DictationError.noSpeech }
            try Task.checkCancellation()
            DebugLog.write("Transcribed \(String(format: "%.1f", Double(samples.count) / AudioRecorder.targetFormat.sampleRate)) s → \(transcription.text.count) chars (\(transcription.detectedLanguage ?? "?"))")

            var text = VocabularyPostProcessor.apply(transcription.text, terms: store.vocabulary)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationError.noSpeech }

            let expansion = MacroExpander.stage1(text, macros: macros, clipboard: capturedClipboard)
            text = expansion.text
            let languageLabel = transcription.detectedLanguage?.uppercased()

            if let prompt = selectedPrompt {
                text = try await applyPrompt(prompt, to: text, languageLabel: languageLabel, hasMacros: !expansion.usedMacroIDs.isEmpty)
                if Task.isCancelled && state.phase == .idle { return }
            }

            text = MacroExpander.stage2(text, macros: macros, clipboard: capturedClipboard)
            state.lastText = text
            state.lastLanguage = transcription.detectedLanguage
            state.phase = .idle
            recordHistory(HistoryEntry(date: Date(), kind: .dictation, text: text, language: transcription.detectedLanguage))

            let inserted = await deliver(text, notice: expansion.clipboardWasEmpty ? "Clipboard was empty" : nil)
            endActivity()
            await pressReturnIfRequested(inserted: inserted)
        } catch is CancellationError {
            if state.phase != .idle {
                DebugLog.write("Pipeline cancelled unexpectedly in phase \(state.phase)")
                state.phase = .idle
                endActivity()
                hud.hide()
            }
        } catch let error as DictationError where error == .noSpeech || error == .tooShort {
            dismissQuietly(reason: error)
            await pressReturnIfRequested(inserted: true)
        } catch {
            DebugLog.write("Pipeline error: \(error)")
            showError(error.localizedDescription)
        }
    }

    private func transcribe(_ engine: SpeechEngine, _ samples: [Float], vocabulary: [VocabularyTerm]) async throws -> Transcription? {
        try await FilteredTranscription.run(engine, samples: samples, language: settings.languageMode, vocabulary: vocabulary,
                                            filterSilence: settings.noiseFilterEnabled, filterHallucinations: settings.noiseFilterEnabled)
    }

    /// Runs the prompt's AI step with an elapsed-seconds ticker. On AI failure the input is returned unchanged.
    private func applyPrompt(_ prompt: NamedPrompt, to text: String, languageLabel: String?, hasMacros: Bool) async throws -> String {
        state.phase = .processing(prompt.name)
        let detailBase = [languageLabel, prompt.name].compactMap { $0 }.joined(separator: " · ")
        hud.update(text: "Processing", detail: detailBase, stage: .processing)
        let instructions = PromptComposer.instructions(for: prompt, vocabulary: store.vocabulary, hasMacros: hasMacros, wantMarkdown: wantsMarkdown)
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
            let result = try await makeProcessor(for: prompt).process(text: text, instructions: instructions)
            ticker.cancel()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ticker.cancel()
            state.lastError = error.localizedDescription
            DebugLog.write("AI failed (\(prompt.name), \(prompt.provider.rawValue), cmd=\(prompt.shellCommand)): \(error)")
            hud.update(text: "AI failed, pasting raw text", stage: .message)
            try? await Task.sleep(for: .milliseconds(900))
            return text
        }
    }

    private func makeProcessor(for prompt: NamedPrompt) -> TextProcessor {
        AIProviderFactory.makeProcessor(provider: prompt.provider, shellTemplate: prompt.shellCommand, settings: settings, context: .prompt)
    }

    /// Nothing was said: fold the HUD away like a cancellation instead of showing an error.
    private func dismissQuietly(reason: DictationError) {
        DebugLog.write("Dismissed quietly: \(reason)")
        endActivity()
        state.phase = .idle
        if settings.soundsEnabled { SoundPlayer.recordingCancelled() }
        hud.hide(reverse: true)
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
