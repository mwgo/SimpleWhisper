import Foundation
import AppKit
import Observation

/// Checks GitHub releases and, when enabled, installs a newer version in place and relaunches.
@MainActor
@Observable
final class Updater {
    static let feedURL = URL(string: ProcessInfo.processInfo.environment["SW_UPDATE_FEED"]
        ?? "https://api.github.com/repos/mwgo/SimpleWhisper/releases/latest")!
    static let bundleIdentifier = "pl.wojas.SimpleWhisper"
    private static let checkInterval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "lastUpdateCheck"

    private(set) var status = "Not checked yet"
    private(set) var isBusy = false
    /// Newer release found but not installed (automatic updates off, or the app folder is not writable).
    private(set) var availableVersion: String?
    private(set) var releasePage: URL?

    /// Set by the controller: installing waits while a dictation is in progress.
    var isIdle: () -> Bool = { true }
    /// Called just before the app quits to be replaced.
    var willRelaunch: (String) -> Void = { _ in }

    private let settings: AppSettings
    private var timer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks once a day: the last check time is kept across launches, the timer only looks whether a day has passed.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard settings.autoUpdateEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(install: true) }
    }

    /// `install: false` only reports (the "Check now" button when automatic updates are off).
    func check(install: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Checking…"
        do {
            let release = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard Self.isNewer(release.version, than: Self.currentVersion) else {
                availableVersion = nil
                status = "Up to date (\(Self.currentVersion)) · checked \(Date().formatted(date: .omitted, time: .shortened))"
                return
            }
            availableVersion = release.version
            releasePage = release.page
            guard install else {
                status = "Version \(release.version) is available"
                return
            }
            guard let reason = Self.cannotInstallReason() else {
                try await waitUntilIdle()
                try await installAndRelaunch(release)
                return
            }
            status = "Version \(release.version) is available · \(reason)"
            DebugLog.write("Update \(release.version) not installed: \(reason)")
        } catch {
            status = "Update check failed: \(error.localizedDescription)"
            DebugLog.write("Update check failed: \(error)")
        }
    }

    // MARK: GitHub

    struct Release {
        var version: String
        var zip: URL
        var page: URL?
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleWhisper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.message("GitHub answered HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.message("unexpected GitHub response") }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String).map { $0.hasPrefix("SimpleWhisper") && $0.hasSuffix(".zip") } ?? false }),
              let link = asset["browser_download_url"] as? String, let zip = URL(string: link) else {
            throw UpdateError.message("release \(tag) has no SimpleWhisper zip")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, zip: zip, page: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    /// nil when the running bundle can be replaced.
    private static func cannotInstallReason() -> String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return "not running from an app bundle" }
        // A development build next to the sources is rebuilt by make-app.sh, not updated.
        let sources = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: sources.path) { return "development build" }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            return "no write access to \(bundle.deletingLastPathComponent().path)"
        }
        return nil
    }

    private func waitUntilIdle() async throws {
        var announced = false
        while !isIdle() {
            if !announced { status = "Update ready, waiting for the dictation to finish…"; announced = true }
            try await Task.sleep(for: .seconds(10))
        }
    }

    private func installAndRelaunch(_ release: Release) async throws {
        status = "Downloading \(release.version)…"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleWhisperUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        status = "Installing \(release.version)…"
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("SimpleWhisper.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier else {
            throw UpdateError.message("downloaded file is not SimpleWhisper")
        }
        guard (info["CFBundleShortVersionString"] as? String) == release.version else {
            throw UpdateError.message("downloaded app has version \(info["CFBundleShortVersionString"] ?? "?"), expected \(release.version)")
        }
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

        // Swap the bundles after this process has exited, then start the new version.
        let target = Bundle.main.bundleURL.path
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "\(target).old"
        /bin/mv "\(target)" "\(target).old" && /bin/mv "\(newApp.path)" "\(target)" && /bin/rm -rf "\(target).old" || /bin/mv "\(target).old" "\(target)"
        /usr/bin/open "\(target)"
        /bin/rm -rf "\(work.path)"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        try helper.run()
        DebugLog.write("Updating \(Self.currentVersion) → \(release.version); relaunching")
        status = "Restarting into \(release.version)…"
        willRelaunch(release.version)
        try? await Task.sleep(for: .milliseconds(800))
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.message("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
