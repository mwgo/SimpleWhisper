import Foundation
import AppKit
import ApplicationServices

/// Reads the text currently selected in the frontmost application: Accessibility first,
/// then a simulated ⌘C (clipboard restored afterwards).
@MainActor
enum SelectionReader {
    static func selectedText(in app: NSRunningApplication?) async -> String? {
        if let text = accessibilitySelection(), !text.isEmpty {
            return text
        }
        return await copySelection(in: app)
    }

    private static func accessibilitySelection() -> String? {
        guard Permissions.accessibilityGranted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success else { return nil }
        return valueRef as? String
    }

    private static func copySelection(in app: NSRunningApplication?) async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let changeCount = pasteboard.changeCount
        if let app, app != NSRunningApplication.current {
            app.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        postCommandKey(virtualKey: 8) // C
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(60))
            if pasteboard.changeCount != changeCount { break }
        }
        guard pasteboard.changeCount != changeCount else { return nil }
        let selection = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return selection
    }

    static func postCommandKey(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
