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
    /// Another key was pressed right after fn started a recording: it was a shortcut (fn+F12…), not dictation.
    func hotkeyCancelSilently()
    /// A character typed while recording: selects the prompt with that shortcut (space = no prompt).
    /// Returns true when consumed (the key is then swallowed).
    func hotkeyPromptShortcut(_ character: String) -> Bool
    /// Return pressed during a dictation: finish it and press Return after the text. Returns true if handled.
    func hotkeyReturn() -> Bool
    /// Return with modifiers (Shift+Return…) while the dictation is marked text in the app: commit it first,
    /// then press the key again. Returns true if handled.
    func hotkeyReturnInInputMethod(flags: CGEventFlags) -> Bool
    /// Live typing editor is open: keys belong to the editor (only fn and Esc keep their meaning).
    var isLiveEditing: Bool { get }
}

/// Which modifier key starts dictation.
enum HotkeyKey: String, CaseIterable, Codable, Identifiable {
    case fn
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: return "🌐 fn (Globe)"
        case .leftCommand: return "⌘ Left Command"
        case .rightCommand: return "⌘ Right Command"
        case .leftOption: return "⌥ Left Option"
        case .rightOption: return "⌥ Right Option"
        }
    }

    /// Short label used in the settings legend.
    var symbol: String {
        switch self {
        case .fn: return "🌐 fn"
        case .leftCommand: return "⌘ left"
        case .rightCommand: return "⌘ right"
        case .leftOption: return "⌥ left"
        case .rightOption: return "⌥ right"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        }
    }

    /// keyDown codes the key itself may emit (the Globe key also sends 179); never counted as "another key".
    var ownKeyDownCodes: Set<Int64> {
        self == .fn ? [63, 179] : [keyCode]
    }
}

enum HotkeyError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Could not install the global key listener. Grant Accessibility and Input Monitoring access, then relaunch."
    }
}

/// Global listener for the Globe/fn key (toggle or push-to-talk) and ESC (cancel).
final class HotkeyMonitor {
    private static let escapeKeyCode: Int64 = 53
    private static let stateFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift]
    /// Return and the keypad Enter.
    private static let returnKeyCodes: Set<Int64> = [36, 76]
    private static let controlKeyCodes: Set<Int64> = [59, 62]
    /// Shift, Control, Option, Command (left/right) and Caps Lock.
    private static let modifierKeyCodes: Set<Int64> = [56, 60, 59, 62, 58, 61, 54, 55, 57]

    private static func hasOtherModifiers(_ flags: CGEventFlags, besides trigger: CGEventFlags) -> Bool {
        let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        return !flags.intersection(others).subtracting(trigger).isEmpty
    }

    /// The key that starts dictation (fn by default; left/right Command or Option).
    var triggerKey: HotkeyKey = .fn

    /// Right Command + letter types a Polish letter, other letters as they are; right Command + hex code types
    /// that Unicode character on release; right Command + Space opens Emoji & Symbols (unless right Command is the dictation key).
    var polishLetters = false
    /// Key codes (QWERTY positions) of a c e l n o s x z and their Polish letters.
    private static let polishLetterKeys: [Int64: Character] = [0: "ą", 8: "ć", 14: "ę", 37: "ł", 45: "ń", 31: "ó", 1: "ś", 7: "ź", 6: "ż"]
    private static let rightCommandDeviceFlag: UInt64 = 0x10
    private static let rightCommandKeyCode: Int64 = 54
    private static let spaceKeyCode: Int64 = 49
    private var rightCommandDown = false
    /// Hex digits typed while right Command is held; the character with that code is typed on release.
    private var unicodeCode = ""
    /// Key codes of 0–9 (main row and keypad) and a–f.
    private static let hexDigitKeys: [Int64: Character] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f",
    ]
    /// Marks the letters this monitor types itself, so it lets them through untouched.
    private static let syntheticMarker: Int64 = 0x5357_504c

    weak var delegate: HotkeyMonitorDelegate?
    var holdThreshold: TimeInterval = 0.4
    /// Any key within this window after fn started recording cancels it silently.
    var shortcutGrace: TimeInterval = 1.0
    private var recordingStartedByFnAt: Date?
    /// Double-press mode: a single fn press does nothing; press-release-press (quick) toggles,
    /// press-release-press-and-hold is push-to-talk. A single press still stops an active dictation.
    var doublePressMode = false
    var doublePressWindow: TimeInterval = 0.4
    private var lastShortReleaseAt: Date?
    private var isSecondPress = false

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
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == Self.rightCommandKeyCode {
            rightCommandDown = event.flags.contains(.maskCommand)
            if !rightCommandDown { typeUnicodeCode() }
        }
        if type == .keyDown, polishLetters, triggerKey != .rightCommand, event.flags.contains(.maskCommand),
           rightCommandDown || event.flags.rawValue & Self.rightCommandDeviceFlag != 0,
           !event.flags.contains(.maskControl), !event.flags.contains(.maskAlternate) {
            if keyCode == Self.spaceKeyCode {
                unicodeCode = ""
                Self.showCharacterViewer()
                return nil
            }
            // A code starts with a digit (0e9, 2014); after that a–f are hex digits too.
            if let digit = Self.hexDigitKeys[keyCode], digit.isNumber || !unicodeCode.isEmpty {
                if unicodeCode.count < 6 { unicodeCode.append(digit) }
                return nil
            }
            if let letter = Self.polishLetterKeys[keyCode] ?? Self.plainLetter(of: event) {
                let capital = event.flags.contains(.maskShift) != event.flags.contains(.maskAlphaShift)
                Self.type(capital ? Character(letter.uppercased()) : letter)
                return nil
            }
        }
        var live = false
        MainActor.assumeIsolated { live = delegate?.isLiveEditing ?? false }
        switch type {
        case .flagsChanged where keyCode == triggerKey.keyCode:
            if event.flags.contains(triggerKey.flag) {
                // fn pressed while another modifier is already held (ctrl+fn…) is someone else's shortcut.
                fnPressed(asCombo: !live && Self.hasOtherModifiers(event.flags, besides: triggerKey.flag))
            } else {
                fnReleased()
            }
        case .flagsChanged where !live && Self.modifierKeyCodes.contains(keyCode) && (fnDownAt != nil && !pushToTalkActive || recentlyStartedByFn):
            // A modifier pressed together with fn (or right after a short fn press) is a shortcut, not dictation.
            comboUsed = true
            if recentlyStartedByFn {
                recordingStartedByFnAt = nil
                pushToTalkActive = false
                cancelHold()
                MainActor.assumeIsolated { delegate?.hotkeyCancelSilently() }
            }
            cancelHold()
        case .flagsChanged where !live && Self.controlKeyCodes.contains(keyCode) && event.flags.contains(.maskControl):
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
            } else if Self.returnKeyCodes.contains(keyCode), !recentlyStartedByFn, fnDownAt == nil || pushToTalkActive {
                // The dictation key held for push-to-talk does not count as a modifier.
                let flags = event.flags.intersection(Self.stateFlags).subtracting(pushToTalkActive ? triggerKey.flag : [])
                var finished = false, forwarded = false
                MainActor.assumeIsolated {
                    finished = flags.isEmpty && delegate?.hotkeyReturn() == true
                    forwarded = !finished && delegate?.hotkeyReturnInInputMethod(flags: flags) == true
                }
                if finished || forwarded {
                    cancelHold()
                    if finished { pushToTalkActive = false }
                    comboUsed = true
                    return nil
                }
            } else if live {
                // Letters belong to the editor; Control + letter picks a prompt, Control + space plain text.
                if event.flags.contains(.maskControl), !event.flags.contains(.maskCommand),
                   let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, character.count == 1,
                   promptShortcut(character) {
                    return nil
                }
            } else if let character = Self.character(of: event), !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl),
                      promptShortcut(character) {
                return nil
            } else if !triggerKey.ownKeyDownCodes.contains(keyCode), fnDownAt != nil || recentlyStartedByFn {
                // fn+key (or a key right after a short fn press) is a keyboard shortcut, not dictation.
                comboUsed = true
                if recentlyStartedByFn {
                    recordingStartedByFnAt = nil
                    pushToTalkActive = false
                    cancelHold()
                    MainActor.assumeIsolated { delegate?.hotkeyCancelSilently() }
                }
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func typeUnicodeCode() {
        defer { unicodeCode = "" }
        guard let value = UInt32(unicodeCode, radix: 16), value >= 0x20, let scalar = Unicode.Scalar(value) else { return }
        Self.type(Character(scalar))
    }

    /// Presses Return (with `flags`) in the frontmost app.
    static func pressReturn(flags: CGEventFlags = []) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: keyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Sends ⌃⌘Space, the system shortcut for Emoji & Symbols, to the frontmost app.
    private static func showCharacterViewer() {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(spaceKeyCode), keyDown: keyDown) else { continue }
            event.flags = [.maskControl, .maskCommand]
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// The letter the key types without modifiers, nil for digits, punctuation and other keys.
    private static func plainLetter(of event: CGEvent) -> Character? {
        guard let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1, let letter = characters.first, letter.isLetter else { return nil }
        return letter
    }

    /// Types `letter` into the frontmost app as if from the keyboard, without modifiers.
    private static func type(_ letter: Character) {
        let units = Array(String(letter).utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func promptShortcut(_ character: String) -> Bool {
        var handled = false
        MainActor.assumeIsolated { handled = delegate?.hotkeyPromptShortcut(character) ?? false }
        return handled
    }

    private static func character(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: buffer, count: length)
        return string.count == 1 ? string : nil
    }

    private var recentlyStartedByFn: Bool {
        guard let started = recordingStartedByFnAt else { return false }
        return Date().timeIntervalSince(started) < shortcutGrace
    }

    private func fnPressed(asCombo: Bool) {
        guard fnDownAt == nil else { return }
        fnDownAt = Date()
        comboUsed = asCombo
        if asCombo { return }
        pushToTalkActive = false
        if doublePressMode {
            isSecondPress = lastShortReleaseAt.map { Date().timeIntervalSince($0) < doublePressWindow } ?? false
            lastShortReleaseAt = nil
        }
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self, self.fnDownAt != nil, !self.comboUsed else { return }
            // In double-press mode only the second press may start push-to-talk.
            if self.doublePressMode && !self.isSecondPress { return }
            self.pushToTalkActive = true
            self.recordingStartedByFnAt = Date()
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
            var active = false
            MainActor.assumeIsolated { active = delegate?.isDictationActive ?? false }
            if doublePressMode && !active && !isSecondPress {
                // First short press: wait for a second one.
                lastShortReleaseAt = Date()
                return
            }
            isSecondPress = false
            var started = false
            MainActor.assumeIsolated {
                let wasIdle = !(delegate?.isDictationActive ?? false)
                delegate?.hotkeyToggle()
                started = wasIdle
            }
            recordingStartedByFnAt = started ? Date() : nil
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
