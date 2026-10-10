import AppKit
import Carbon
import InputMethodKit

/// Passes every key through (with the user's keyboard layout); SimpleWhisper drives it with
/// marked text while dictating and inserts the final text when the dictation ends.
@objc(SWInputController)
final class SWInputController: IMKInputController {
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // Typing or clicking while the dictation is shown as marked text keeps it where it is.
        if event.type == .keyDown || event.type == .leftMouseDown {
            IMEBridge.shared.userInput(for: self)
        }
        return false
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        if let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            TISSetInputMethodKeyboardLayoutOverride(layout)
        }
        IMEBridge.shared.activate(self, client: sender as? IMKTextInput)
    }

    override func deactivateServer(_ sender: Any!) {
        IMEBridge.shared.deactivate(self)
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        IMEBridge.shared.commitPending(for: self, reason: "commit")
    }
}

/// Receives commands from SimpleWhisper over distributed notifications and applies them to the focused client.
final class IMEBridge: NSObject {
    static let shared = IMEBridge()
    static let commandName = Notification.Name("pl.wojas.SimpleWhisper.ime.command")
    static let statusName = Notification.Name("pl.wojas.SimpleWhisper.ime.status")
    private static let none = NSRange(location: NSNotFound, length: 0)

    private weak var controller: SWInputController?
    private var client: IMKTextInput?
    private var marked = ""
    /// SimpleWhisper is dictating: report typing and clicks so it can re-read the text around the caret.
    private var sessionActive = false

    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(command(_:)), name: Self.commandName,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    func activate(_ controller: SWInputController, client: IMKTextInput?) {
        self.controller = controller
        self.client = client
        marked = ""
    }

    func deactivate(_ controller: SWInputController) {
        guard controller === self.controller else { return }
        commitPending(for: controller, reason: "deactivate")
        self.controller = nil
        client = nil
    }

    func userInput(for controller: SWInputController) {
        guard controller === self.controller else { return }
        if !marked.isEmpty {
            commitPending(for: controller, reason: "input")
        } else if sessionActive {
            post(["event": "input"])
        }
    }

    func commitPending(for controller: SWInputController, reason: String) {
        guard controller === self.controller, !marked.isEmpty else { return }
        client?.insertText(marked, replacementRange: Self.none)
        marked = ""
        post(["event": "committed", "reason": reason])
    }

    @objc private func command(_ note: Notification) {
        guard let info = note.userInfo, let op = info["op"] as? String else { return }
        if op == "begin" || op == "end" {
            sessionActive = op == "begin"
            return
        }
        let token = info["token"] as? String ?? ""
        let text = info["text"] as? String ?? ""
        guard let client else {
            post(["event": "failed", "op": op, "token": token, "reason": "noClient"])
            return
        }
        let app = client.bundleIdentifier() ?? ""
        if let target = info["target"] as? String, target != app {
            post(["event": "failed", "op": op, "token": token, "reason": "wrongClient", "app": app])
            return
        }
        switch op {
        case "ping":
            post(["event": "pong", "token": token, "app": app, "before": textBeforeCaret(client), "after": textAfterCaret(client)])
            return
        case "mark":
            marked = text
            client.setMarkedText(text, selectionRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: Self.none)
        case "commit":
            client.insertText(text, replacementRange: Self.none)
            marked = info["marked"] as? String ?? ""
            if !marked.isEmpty {
                client.setMarkedText(marked, selectionRange: NSRange(location: (marked as NSString).length, length: 0), replacementRange: Self.none)
            }
        case "insert":
            marked = ""
            if text.isEmpty {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.none)
            } else {
                client.insertText(text, replacementRange: Self.none)
            }
        default:
            return
        }
        post(["event": "done", "op": op, "token": token])
    }

    /// Up to 80 characters before the caret, for spacing and capitalisation; empty when the client does not tell.
    private func textBeforeCaret(_ client: IMKTextInput) -> String {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return "" }
        let length = min(80, selection.location)
        let range = NSRange(location: selection.location - length, length: length)
        return client.attributedSubstring(from: range)?.string ?? ""
    }

    /// Up to 40 characters after the caret (or selection), so the dictation gets a trailing space where needed.
    private func textAfterCaret(_ client: IMKTextInput) -> String {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return "" }
        let start = selection.location + selection.length
        let length = max(0, min(40, client.length() - start))
        guard length > 0 else { return "" }
        return client.attributedSubstring(from: NSRange(location: start, length: length))?.string ?? ""
    }

    private func post(_ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(Self.statusName, object: nil, userInfo: info, deliverImmediately: true)
    }
}
