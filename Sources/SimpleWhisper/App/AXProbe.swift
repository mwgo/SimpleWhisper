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
        if CommandLine.arguments.contains("--deep") { deepSearch(from: element) }
        var parent = element
        for level in 1...6 {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(parent, kAXParentAttribute as CFString, &ref) == .success, let ref else { break }
            parent = ref as! AXUIElement
            print("parent \(level): \(role(parent)) / \(attr(parent, kAXSubroleAttribute) ?? "-") / \(attr(parent, kAXDescriptionAttribute) ?? "-")")
        }
    }

    /// Breadth-first search for focused or text-like descendants (depth ≤ 25, ≤ 3000 nodes).
    private static func deepSearch(from root: AXUIElement) {
        var queue: [(AXUIElement, Int, String)] = [(root, 0, "root")]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let (element, depth, path) = queue.removeFirst()
            visited += 1
            let r = role(element)
            var focusedRef: CFTypeRef?
            let focused = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success && (focusedRef as? Bool ?? false)
            var editableRef: CFTypeRef?
            let editable = AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editableRef) == .success
            if focused || editable || ["AXTextArea", "AXTextField", "AXWebArea"].contains(r) {
                print("  [\(depth)] \(path): \(r) / \(attr(element, kAXSubroleAttribute) ?? "-") / \(attr(element, kAXDescriptionAttribute) ?? "-") focused=\(focused) editable=\(editable) classes=\(attr(element, "AXDOMClassList") ?? "-")")
            }
            guard depth < 25 else { continue }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success, let children = childrenRef as? [AXUIElement] {
                for (i, c) in children.enumerated() { queue.append((c, depth + 1, path + "/\(i)")) }
            }
        }
        print("  visited \(visited) nodes")
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
