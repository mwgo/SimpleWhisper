import AppKit
import SwiftUI

/// Borderless panels cannot become key by default; the Live typing editor needs keyboard focus.
/// Being non-activating, it takes the keyboard without making SimpleWhisper the active app.
final class HUDPanel: NSPanel {
    var acceptsKey = false
    /// Esc while the result card is shown (the dictation hotkey tap only handles Esc during dictation).
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKey }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}

/// Small floating capsule shown near the text caret while dictation is active.
@MainActor
final class HUDWindowController: NSObject {
    let model = HUDModel()
    var promptsProvider: () -> [NamedPrompt] = { [] }
    var selectedPromptID: () -> UUID? = { nil }
    var onSelectPrompt: (UUID?) -> Void = { _ in }
    var onRunCommand: () -> Void = {}

    private let panel: HUDPanel
    private let hostingView: NSHostingView<HUDView>
    private var hideTask: Task<Void, Never>?
    private var anchor: CaretLocator.Anchor?
    /// Set by the controller from settings before each show.
    var placement: HUDPlacement = .nearCaret
    var theme: HUDTheme {
        get { model.theme }
        set { model.theme = newValue }
    }
    /// Glass renders its own translucency; the solid fill is made slightly see-through by the panel instead.
    var glass: Bool {
        get { model.glass }
        set {
            model.glass = newValue
            panel.alphaValue = newValue ? 1 : 0.85
        }
    }
    /// Mirrors the "show status text" setting.
    var showsText: Bool {
        get { model.showsText }
        set { model.showsText = newValue }
    }

    override init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow is derived from the window's alpha mask and lags behind the scale
        // animation, leaving a thin dark rim around the capsule; the capsule draws its own shadow.
        panel.hasShadow = false
        // Slightly see-through so the HUD never fully hides what it floats over.
        panel.alphaValue = 0.85
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        hostingView = NSHostingView(rootView: HUDView(model: model, onTap: {}))
        super.init()
        hostingView.rootView = HUDView(
            model: model,
            onTap: { [weak self] in self?.showPromptMenu() },
            onCommand: { [weak self] in self?.onRunCommand() },
            onCopyResult: { [weak self] in self?.copyResult() },
            onCloseResult: { [weak self] in self?.hide() }
        )
        panel.contentView = hostingView
    }

    func show(text: String, detail: String? = nil, stage: HUDStage, commandButton: Bool = false, liveEditor: LiveEditorController? = nil) {
        hideTask?.cancel()
        anchor = CaretLocator.anchor(placement: liveEditor != nil && placement == .hidden ? .nearCaret : placement)
        model.showsCommandButton = commandButton
        model.resetLevels()
        model.resultMode = false
        panel.onEscape = nil
        attach(liveEditor)
        model.appearance += 1
        update(text: text, detail: detail, stage: stage)
        if liveEditor != nil {
            panel.makeKeyAndOrderFront(nil)
            liveEditor?.focus()
        } else if placement != .hidden {
            panel.orderFrontRegardless()
        }
    }

    private func attach(_ liveEditor: LiveEditorController?) {
        model.liveEditor = liveEditor
        panel.acceptsKey = liveEditor != nil
        guard let liveEditor else { return }
        liveEditor.inkColor = model.glass ? .labelColor : NSColor(model.theme.ink)
        liveEditor.textShadow = model.glass
        model.editorSize = liveEditor.size
        liveEditor.onSizeChange = { [weak self] size in
            self?.model.editorSize = size
            DispatchQueue.main.async { self?.layout() }
        }
    }

    /// Shows a finished text that could not be pasted in the editor card, with Copy and Close.
    /// Reuses the live card in place when it is open; otherwise opens it at the usual anchor.
    func showResult(_ text: String, editor: LiveEditorController) {
        hideTask?.cancel()
        hideTask = nil
        let wasShowingEditor = panel.isVisible && model.liveEditor === editor
        if !wasShowingEditor {
            anchor = CaretLocator.anchor(placement: placement == .hidden ? .nearCaret : placement)
            model.appearance += 1
        }
        attach(editor)
        editor.setText(text)
        model.editorSize = editor.size
        model.resultMode = true
        model.stage = .message
        panel.onEscape = { [weak self] in self?.hide() }
        layout()
        DispatchQueue.main.async { [weak self] in self?.layout() }
        panel.makeKeyAndOrderFront(nil)
        editor.focus()
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { editor.scrollToTopIfFits() }
        }
    }

    private func copyResult() {
        guard let editor = model.liveEditor else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editor.text, forType: .string)
        hide()
    }

    func update(text: String, detail: String? = nil, stage: HUDStage) {
        hideTask?.cancel()
        model.text = text
        model.detail = detail
        if model.stage != stage {
            model.stage = stage
            model.resetLevels()
        }
        layout()
        // SwiftUI resizes the capsule asynchronously; re-centre once the new size is known.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// Feeds the microphone level (0…1) to the recording animation.
    func setLevel(_ level: Double) {
        guard model.stage == .recording else { return }
        model.push(level: level)
    }

    /// Shows a short message, then hides. `reverseDismiss` folds the capsule away to the left (cancellation).
    func flash(_ text: String, duration: Duration = .seconds(1.2), reverseDismiss: Bool = false) {
        guard placement != .hidden else { return }
        if !panel.isVisible {
            anchor = CaretLocator.anchor(placement: placement)
            model.appearance += 1
            panel.orderFrontRegardless()
        }
        update(text: text, detail: nil, stage: .message)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide(reverse: reverseDismiss)
        }
    }

    /// Plays the disappear animation, then removes the panel. `animated: false` hides immediately.
    func hide(animated: Bool = true, reverse: Bool = false) {
        hideTask?.cancel()
        hideTask = nil
        guard animated, panel.isVisible else {
            orderOut()
            return
        }
        model.dismissReversed = reverse
        model.dismissal += 1
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self?.hideTask = nil
            self?.orderOut()
        }
    }

    private func orderOut() {
        panel.orderOut(nil)
        panel.acceptsKey = false
        panel.onEscape = nil
        model.liveEditor = nil
        model.resultMode = false
    }

    /// Human-readable description of the last anchor, for the menu bar status.
    var anchorDescription: String? {
        guard let anchor else { return nil }
        let app = anchor.appName.map { " in \($0)" } ?? ""
        return "\(anchor.source.rawValue)\(app)"
    }

    /// Full diagnostics of the last anchor computation plus the resulting panel frame.
    var anchorDebug: String? {
        guard let anchor else { return nil }
        let frame = panel.frame
        return "\(anchor.debug) point=(\(Int(anchor.point.x)),\(Int(anchor.point.y))) panel=(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))) screen=\(NSScreen.screens.first.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "?")"
    }

    private func layout() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard let anchor else { return }
        var origin: CGPoint
        let pad = HUDView.outerPadding   // transparent margin around the capsule (ripple room)
        switch anchor.source {
        case .screen:
            origin = CGPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y - pad)
        case .screenTop:
            origin = CGPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y - size.height + pad)
        case .caret, .focusedElement:
            origin = CGPoint(x: anchor.point.x - pad, y: anchor.point.y - 10 - size.height + pad)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y < visible.minY + 8 {
                origin.y = anchor.source == .screen ? visible.minY + 8 : anchor.point.y + 28
            }
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = visible.maxY - 8 - size.height
            }
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.isVisible, panel.frame.size != .zero, model.liveEditor == nil, abs(panel.frame.width - frame.width) > 0.5 || abs(panel.frame.height - frame.height) > 0.5 {
            // Animate the window in step with the SwiftUI content animation (see HUDView.layoutKey).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func showPromptMenu() {
        let menu = NSMenu()
        let current = selectedPromptID()
        let plain = NSMenuItem(title: "Plain text (no prompt)", action: #selector(selectPrompt(_:)), keyEquivalent: "")
        plain.target = self
        plain.state = current == nil ? .on : .off
        menu.addItem(plain)
        let prompts = promptsProvider()
        if !prompts.isEmpty { menu.addItem(.separator()) }
        for prompt in prompts {
            let item = NSMenuItem(title: prompt.name, action: #selector(selectPrompt(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prompt.id
            item.state = prompt.id == current ? .on : .off
            menu.addItem(item)
        }
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    @objc private func selectPrompt(_ sender: NSMenuItem) {
        onSelectPrompt(sender.representedObject as? UUID)
    }
}
