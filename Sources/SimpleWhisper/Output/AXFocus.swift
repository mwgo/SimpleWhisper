import Foundation
import AppKit
import ApplicationServices

/// Finds the UI element that currently has keyboard focus.
///
/// The system-wide query is enough for native apps, but Electron-based ones (Microsoft Teams,
/// Slack…) keep their accessibility tree switched off until an assistive client asks for it by
/// setting `AXManualAccessibility` on the application element. We do that on the frontmost app
/// and query its focused element directly as a fallback.
enum AXFocus {
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            return (focusedRef as! AXUIElement)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var appFocusedRef: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedRef)
        if status != .success {
            // The tree is built lazily after the flag is set; give the app a moment and ask once more.
            usleep(150_000)
            status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedRef)
        }
        guard status == .success, let appFocusedRef else {
            DebugLog.write("AXFocus: no focused element in \(app.localizedName ?? "?") (status \(status.rawValue))")
            return nil
        }
        return (appFocusedRef as! AXUIElement)
    }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField", "AXSecureTextField",
    ]
    private static let containerRoles: Set<String> = [
        kAXSplitGroupRole as String, kAXGroupRole as String, kAXScrollAreaRole as String, kAXLayoutAreaRole as String,
    ]

    /// The focused element, or – when focus sits on a container (Word hands focus to a split group
    /// around the document) – the first text element inside it.
    static func focusedTextElement() -> AXUIElement? {
        guard let focused = focusedElement() else { return nil }
        return textElement(within: focused)
    }

    static func textElement(within focused: AXUIElement) -> AXUIElement {
        let focusedRole = role(of: focused)
        if focusedRole == "AXWebArea", let inner = focusedDescendant(of: focused) {
            // Chromium reports the (i)frame's web area as focused; the real focus is a node inside it.
            DebugLog.write("AXFocus: focus on AXWebArea, using focused descendant \(role(of: inner))")
            return inner
        }
        guard containerRoles.contains(focusedRole) || focusedRole == (kAXWindowRole as String) else { return focused }
        var queue = [focused]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1
            let elementRole = role(of: element)
            if textRoles.contains(elementRole) {
                DebugLog.write("AXFocus: focus on \(focusedRole), using nested \(elementRole)")
                return element
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return focused
    }

    private static func focusedDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = []
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] { queue = children }
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let element = queue.removeFirst()
            visited += 1
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success,
               focusedRef as? Bool == true, role(of: element) != "AXWebArea" {
                return element
            }
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
               let children = ref as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }

    /// True for nodes inside a `contenteditable` region (Chromium/WebKit expose `AXEditableAncestor`).
    static func hasEditableAncestor(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ref) == .success
    }

    static func role(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return "" }
        return ref as? String ?? ""
    }
}
