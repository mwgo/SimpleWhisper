import Foundation
import AppKit
import CoreGraphics

/// Puts text on the clipboard and pastes it into the application that was active when dictation began.
@MainActor
final class TextPaster {
    private var targetApp: NSRunningApplication?

    func rememberTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front == NSRunningApplication.current ? targetApp : front
    }

    func paste(_ text: String, keepInClipboard: Bool) async {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let app = targetApp, app != NSRunningApplication.current {
            app.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        sendCommandV()

        if !keepInClipboard, let previous {
            try? await Task.sleep(for: .milliseconds(600))
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
