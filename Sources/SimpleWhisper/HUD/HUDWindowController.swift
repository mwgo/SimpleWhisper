import AppKit
import SwiftUI

/// Small floating capsule shown near the text caret while dictation is active.
@MainActor
final class HUDWindowController: NSObject {
    let model = HUDModel()
    var promptsProvider: () -> [NamedPrompt] = { [] }
    var selectedPromptID: () -> UUID? = { nil }
    var onSelectPrompt: (UUID?) -> Void = { _ in }
    var onRunCommand: () -> Void = {}

    private let panel: NSPanel
    private let hostingView: NSHostingView<HUDView>
    private var hideTask: Task<Void, Never>?
    private var anchor: CaretLocator.Anchor?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        hostingView = NSHostingView(rootView: HUDView(model: model, onTap: {}))
        super.init()
        hostingView.rootView = HUDView(
            model: model,
            onTap: { [weak self] in self?.showPromptMenu() },
            onCommand: { [weak self] in self?.onRunCommand() }
        )
        panel.contentView = hostingView
    }

    func show(text: String, detail: String? = nil, stage: HUDStage, commandButton: Bool = false) {
        hideTask?.cancel()
        anchor = CaretLocator.anchor()
        model.showsCommandButton = commandButton
        model.resetLevels()
        update(text: text, detail: detail, stage: stage)
        panel.orderFrontRegardless()
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
    }

    /// Feeds the microphone level (0…1) to the recording animation.
    func setLevel(_ level: Double) {
        guard model.stage == .recording else { return }
        model.push(level: level)
    }

    /// Shows a short message, then hides.
    func flash(_ text: String, duration: Duration = .seconds(1.2)) {
        if !panel.isVisible {
            anchor = CaretLocator.anchor()
            panel.orderFrontRegardless()
        }
        update(text: text, detail: nil, stage: .message)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
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
        let size = hostingView.fittingSize
        guard let anchor else { return }
        var origin: CGPoint
        switch anchor.source {
        case .screen:
            origin = CGPoint(x: anchor.point.x - size.width / 2, y: anchor.point.y)
        case .caret, .focusedElement:
            origin = CGPoint(x: anchor.point.x, y: anchor.point.y - 10 - size.height)
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
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
