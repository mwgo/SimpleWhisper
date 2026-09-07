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
}
