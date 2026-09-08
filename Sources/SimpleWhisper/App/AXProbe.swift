import Foundation
import AppKit
import ApplicationServices

/// Prints the focused accessibility element of the frontmost app: `--ax-probe`.
enum AXProbe {
    static func run() {
        guard let element = AXFocus.focusedElement() else { print("no focused element"); return }
        print("frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        if CommandLine.arguments.contains("--from-window"), let app = NSWorkspace.shared.frontmostApplication {
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef {
                let found = AXFocus.textElement(within: windowRef as! AXUIElement)
                print("from window: \(role(found)) / \(attr(found, kAXDescriptionAttribute) ?? "-")")
            }
        }
        print("can paste: \(MainActor.assumeIsolated { PasteTargetProbe.canPasteIntoFocusedElement() })")
        if let text = AXFocus.focusedTextElement() { print("text element: \(role(text)) / \(attr(text, kAXDescriptionAttribute) ?? "-")") }
        dump(element, label: "focused", depth: 0, maxDepth: 3)
        var parent = element
        for level in 1...6 {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parent, kAXParentAttribute as CFString, &ref) == .success, let ref else { break }
            parent = ref as! AXUIElement
            print("parent \(level): \(role(parent)) / \(attr(parent, kAXSubroleAttribute) ?? "-") / \(attr(parent, kAXDescriptionAttribute) ?? "-")")
        }
    }

    private static func dump(_ element: AXUIElement, label: String, depth: Int, maxDepth: Int) {
        let indent = String(repeating: "  ", count: depth)
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let attributes = (names as? [String]) ?? []
        print("\(indent)\(label): \(role(element)) / \(attr(element, kAXSubroleAttribute) ?? "-") / \(attr(element, kAXDescriptionAttribute) ?? "-")")
        if depth == 0 || role(element) == "AXLayoutArea" { print("\(indent)  attributes: \(attributes.joined(separator: " "))") }
        guard depth < maxDepth else { return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for (index, child) in children.prefix(12).enumerated() {
            dump(child, label: "child \(index)", depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private static func role(_ element: AXUIElement) -> String { attr(element, kAXRoleAttribute) ?? "?" }

    private static func attr(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
