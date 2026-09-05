import Foundation
import AppKit
import ApplicationServices

/// Decides whether the frontmost application currently has a place to paste text into.
@MainActor
enum PasteTargetProbe {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
        "AXSearchField", "AXSecureTextField",
    ]
    private static let nonEditableRoles: Set<String> = [
        "AXWebArea", kAXStaticTextRole as String, kAXWindowRole as String, kAXGroupRole as String,
        kAXScrollAreaRole as String, kAXButtonRole as String, kAXImageRole as String, kAXListRole as String,
        kAXTableRole as String, kAXOutlineRole as String, kAXRowRole as String, kAXCellRole as String,
    ]

    /// True when a text-editing element has keyboard focus. Without Accessibility we cannot tell
    /// and assume pasting works (the previous behaviour).
    static func canPasteIntoFocusedElement() -> Bool {
        guard Permissions.accessibilityGranted else { return true }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard status == .success, let focusedRef else {
            // Apps that expose no accessibility tree at all (some games, remote desktops): assume yes.
            return status == .cannotComplete || status == .apiDisabled
        }
        let element = focusedRef as! AXUIElement
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success ? (roleRef as? String ?? "") : ""
        if textRoles.contains(role) { return true }
        if nonEditableRoles.contains(role) { return false }
        // Unknown role (custom editors): editable if it exposes a selected-text range.
        var rangeRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
    }
}
