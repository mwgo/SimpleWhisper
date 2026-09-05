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
        // Accessibility says the selection is empty: trust it. (⌘C would copy the whole line in VS Code.)
        if let length = accessibilitySelectionLength(), length == 0 {
            return nil
        }
        return await copySelection(in: app)
    }

    private static func accessibilitySelectionLength() -> Int? {
        guard Permissions.accessibilityGranted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range.length
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

    /// Selects the text that was just pasted (it ends at the caret) so a paste replaces it: ⇧← once per
    /// character, then verifies the selection. Setting the range via Accessibility is not used because
    /// Chromium reports success but only moves the caret. Returns true when the selection matches `expected`.
    static func selectBackwards(expected: String, in app: NSRunningApplication?) async -> Bool {
        let length = expected.count
        guard length > 0, length <= 3000 else { return false }
        if let app, app != NSRunningApplication.current {
            app.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        for index in 0..<length {
            postKey(virtualKey: 123, flags: .maskShift) // ⇧←
            if index % 40 == 39 { try? await Task.sleep(for: .milliseconds(15)) }
        }
        try? await Task.sleep(for: .milliseconds(150))
        // Verify with ⌘C (Accessibility is stale in Electron editors right after keyboard selection).
        let selected = await copySelection(in: app) ?? ""
        let normalize: (String) -> String = {
            $0.replacingOccurrences(of: "\r\n", with: "\n")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        if normalize(selected) == normalize(expected) { return true }
        // Wrong selection: collapse back to the original caret position (right end) and give up.
        postKey(virtualKey: 124, flags: []) // →
        try? await Task.sleep(for: .milliseconds(80))
        return false
    }

    static func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
