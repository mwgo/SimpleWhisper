import AppKit
import Carbon

/// Talks to the SimpleWhisper input method (a separate bundle in ~/Library/Input Methods). When the user
/// has it selected as their input source, Live typing shows the dictation in the app itself as marked
/// text and inserts it at the end, instead of using the HUD editor.
@MainActor
final class InputSourceBridge {
    static let sourceID = "pl.wojas.inputmethod.SimpleWhisper"
    private static let commandName = Notification.Name("pl.wojas.SimpleWhisper.ime.command")
    private static let statusName = Notification.Name("pl.wojas.SimpleWhisper.ime.status")
    private static let bundleName = "SimpleWhisperIME.app"

    enum Status: Equatable {
        case unavailable      // no input method bundle inside this build
        case notInstalled
        case notEnabled       // installed, not added in Keyboard settings
        case notSelected
        case selected
    }

    /// The text in the client was committed by the user (typing, clicking, switching apps).
    var onCommitted: () -> Void = {}
    /// The user typed or clicked in the client while nothing was marked.
    var onInput: () -> Void = {}

    private var target = ""
    private var waiting: [String: CheckedContinuation<[String: String]?, Never>] = [:]

    init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.statusName, object: nil, queue: .main) { [weak self] note in
            let info = (note.userInfo as? [String: String]) ?? [:]
            MainActor.assumeIsolated { self?.received(info) }
        }
    }

    // MARK: Session

    /// Prepares a session for `app`; returns the text around its caret, or nil when the input method
    /// is not selected or does not serve that app's focused field.
    func connect(to app: NSRunningApplication?) async -> (before: String, after: String)? {
        guard Self.status == .selected, let bundle = app?.bundleIdentifier else { return nil }
        target = bundle
        guard let reply = await send("ping"), reply["event"] == "pong" else { return nil }
        let before = reply["before"] ?? "", after = reply["after"] ?? ""
        // Some apps (JetBrains IDEs) do not hand text to input methods; accessibility often does.
        if before.isEmpty, after.isEmpty, let around = AXFocus.textAroundCaret() { return around }
        return (before, after)
    }

    /// Tells the input method whether a dictation is running (it then reports typing and clicks).
    func setSessionActive(_ active: Bool) {
        post(active ? "begin" : "end", text: "", token: "")
    }

    func mark(_ text: String) {
        post("mark", text: text, token: "")
    }

    /// Replaces the marked text with `text` (empty removes it); false when the client did not confirm.
    func insert(_ text: String) async -> Bool {
        await send("insert", text: text)?["event"] == "done"
    }

    private func send(_ op: String, text: String = "") async -> [String: String]? {
        let token = UUID().uuidString
        return await withCheckedContinuation { continuation in
            waiting[token] = continuation
            post(op, text: text, token: token)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.waiting.removeValue(forKey: token)?.resume(returning: nil)
            }
        }
    }

    private func post(_ op: String, text: String, token: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.commandName, object: nil,
            userInfo: ["op": op, "text": text, "token": token, "target": target], deliverImmediately: true)
    }

    private func received(_ info: [String: String]) {
        if info["event"] == "committed" {
            DebugLog.write("Input method: marked text committed by the app (\(info["reason"] ?? "?"))")
            onCommitted()
            return
        }
        if info["event"] == "input" {
            onInput()
            return
        }
        if info["event"] == "failed" {
            DebugLog.write("Input method: \(info["op"] ?? "?") failed (\(info["reason"] ?? "?") \(info["app"] ?? ""))")
        }
        if let token = info["token"], let continuation = waiting.removeValue(forKey: token) {
            continuation.resume(returning: info)
        }
    }

    // MARK: Installation

    private static var embeddedURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Input Methods/\(bundleName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/\(bundleName)")
    }

    static var status: Status {
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return embeddedURL == nil ? .unavailable : .notInstalled
        }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let id = current.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        if id == sourceID { return .selected }
        let enabled = TISCreateInputSourceList([kTISPropertyInputSourceID: sourceID] as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] ?? []
        return enabled.isEmpty ? .notEnabled : .notSelected
    }

    /// Copies the input method to ~/Library/Input Methods and registers it. The user then adds it in
    /// Keyboard settings (macOS does not let apps enable input methods themselves).
    static func install() throws {
        guard let embeddedURL else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installedURL.path) { try fileManager.removeItem(at: installedURL) }
        try fileManager.copyItem(at: embeddedURL, to: installedURL)
        TISRegisterInputSource(installedURL as CFURL)
        // A running copy keeps the old code until it is started again by the system.
        NSRunningApplication.runningApplications(withBundleIdentifier: sourceID).forEach { $0.terminate() }
        DebugLog.write("Input method installed at \(installedURL.path)")
    }

    /// Keeps an installed copy in step with this build (after an app update).
    static func updateInstalledCopy() {
        guard let embeddedURL, FileManager.default.fileExists(atPath: installedURL.path) else { return }
        // The signature lists a hash of every file in the bundle, so any change (code, icon, Info.plist) shows.
        let seal = { (url: URL) in
            ["Contents/MacOS/SimpleWhisperIME", "Contents/_CodeSignature/CodeResources"]
                .map { try? Data(contentsOf: url.appendingPathComponent($0)) }
        }
        guard seal(embeddedURL) != seal(installedURL) else { return }
        do { try install() } catch { DebugLog.write("Input method update failed: \(error)") }
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
