import Foundation
import AppKit
import CoreGraphics

@MainActor
protocol HotkeyMonitorDelegate: AnyObject {
    /// True while recording, transcribing or processing. ESC is swallowed only then.
    var isDictationActive: Bool { get }
    func hotkeyToggle()
    func hotkeyPushToTalkStart()
    func hotkeyPushToTalkStop()
    func hotkeyCancel()
    /// Control pressed while recording: finish and run the dictation as a command. Returns true if handled.
    func hotkeyRunCommand() -> Bool
}

enum HotkeyError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Could not install the global key listener. Grant Accessibility and Input Monitoring access, then relaunch."
    }
}

/// Global listener for the Globe/fn key (toggle or push-to-talk) and ESC (cancel).
final class HotkeyMonitor {
    private static let fnKeyCode: Int64 = 63
    private static let escapeKeyCode: Int64 = 53
    private static let controlKeyCodes: Set<Int64> = [59, 62]

    weak var delegate: HotkeyMonitorDelegate?
    var holdThreshold: TimeInterval = 0.4

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: Date?
    private var comboUsed = false
    private var pushToTalkActive = false
    private var holdTimer: Timer?

    var isRunning: Bool { tap != nil }

    func start() throws {
        if tap != nil { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            throw HotkeyError.tapCreationFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged where keyCode == Self.fnKeyCode:
            if event.flags.contains(.maskSecondaryFn) {
                fnPressed()
            } else {
                fnReleased()
            }
        case .flagsChanged where Self.controlKeyCodes.contains(keyCode) && event.flags.contains(.maskControl):
            var handled = false
            MainActor.assumeIsolated { handled = delegate?.hotkeyRunCommand() ?? false }
            if handled {
                // Works both while fn is held (push-to-talk) and after a short fn press (toggle).
                comboUsed = true
                pushToTalkActive = false
                cancelHold()
            }
        case .keyDown:
            if keyCode == Self.escapeKeyCode {
                var swallow = false
                MainActor.assumeIsolated {
                    if let delegate, delegate.isDictationActive {
                        delegate.hotkeyCancel()
                        swallow = true
                    }
                }
                if swallow {
                    cancelHold()
                    pushToTalkActive = false
                    comboUsed = true
                    return nil
                }
            } else if fnDownAt != nil {
                comboUsed = true
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func fnPressed() {
        guard fnDownAt == nil else { return }
        fnDownAt = Date()
        comboUsed = false
        pushToTalkActive = false
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self, self.fnDownAt != nil, !self.comboUsed else { return }
            self.pushToTalkActive = true
            MainActor.assumeIsolated { self.delegate?.hotkeyPushToTalkStart() }
        }
    }

    private func fnReleased() {
        guard let downAt = fnDownAt else { return }
        fnDownAt = nil
        cancelHold()
        defer { pushToTalkActive = false }
        if comboUsed { return }
        if pushToTalkActive {
            MainActor.assumeIsolated { delegate?.hotkeyPushToTalkStop() }
        } else if Date().timeIntervalSince(downAt) < holdThreshold {
            MainActor.assumeIsolated { delegate?.hotkeyToggle() }
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
