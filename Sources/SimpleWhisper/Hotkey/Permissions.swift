import Foundation
import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
    }

    static func openSystemSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
