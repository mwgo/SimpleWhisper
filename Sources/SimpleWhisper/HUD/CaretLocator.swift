import Foundation
import AppKit
import ApplicationServices

/// Finds where to show the HUD. Preference order:
/// 1. below the text caret of the focused element (Accessibility, works in native text views),
/// 2. relative to the focused element's frame (text fields, editors without caret bounds),
/// 3. bottom-centre of the screen.
enum CaretLocator {
    enum Source: String {
        case caret, focusedElement, screen
    }

    struct Anchor {
        /// AppKit screen coordinates. For `.screen` it is the centre of the HUD's bottom edge;
        /// otherwise the point the HUD's top-left corner hangs below.
        var point: CGPoint
        var source: Source
        var appName: String?
        var debug: String = ""
    }

    @MainActor
    static func anchor() -> Anchor {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        var debug: [String] = ["ax=\(Permissions.accessibilityGranted)"]
        if Permissions.accessibilityGranted, let focused = focusedElement() {
            debug.append("role=\(stringAttribute(kAXRoleAttribute, of: focused) ?? "?")")
            let rawCaret = rawCaretRect(of: focused)
            let rawFrame = rawFrame(of: focused)
            debug.append("caretCG=\(rawCaret.map(describe) ?? "nil") frameCG=\(rawFrame.map(describe) ?? "nil")")
            if let raw = rawCaret, let converted = toAppKit(raw) {
                debug.append("→ caret")
                return Anchor(point: CGPoint(x: converted.minX, y: converted.minY), source: .caret, appName: appName, debug: debug.joined(separator: " "))
            }
            if let raw = rawFrame, let frame = toAppKit(raw) {
                // Small controls (text fields): hang below. Large editors: top-left corner inside.
                let point = frame.height < 120
                    ? CGPoint(x: frame.minX, y: frame.minY)
                    : CGPoint(x: frame.minX + 16, y: frame.maxY - 16)
                debug.append("→ element")
                return Anchor(point: point, source: .focusedElement, appName: appName, debug: debug.joined(separator: " "))
            }
        } else {
            debug.append("no focused element")
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        debug.append("→ screen")
        return Anchor(point: CGPoint(x: visible.midX, y: visible.minY + 48), source: .screen, appName: appName, debug: debug.joined(separator: " "))
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// Caret rectangle as reported by Accessibility (top-left-origin global coordinates).
    private static func rawCaretRect(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boundsRef) == .success,
              let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Frame of the element as reported by Accessibility (top-left-origin global coordinates).
    private static func rawFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Accessibility reports top-left-origin global coordinates; AppKit uses a bottom-left origin
    /// on the primary screen. Rejects rectangles that are empty or not on any screen.
    private static func toAppKit(_ rect: CGRect) -> CGRect? {
        // Electron apps (VS Code) report a 0×0 caret rect at the screen corner; ignore anything without a height.
        guard rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.height > 0 else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let probe = CGPoint(x: flipped.midX, y: flipped.midY)
        guard NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(probe) }) else { return nil }
        return flipped
    }
}
