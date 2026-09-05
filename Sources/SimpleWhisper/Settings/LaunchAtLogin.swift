import Foundation
import ServiceManagement
import Observation

/// Registers the app as a login item via SMAppService (System Settings › General › Login Items).
@Observable
@MainActor
final class LaunchAtLogin {
    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound: return "Not available (run from the .app bundle)"
        @unknown default: return "Unknown"
        }
    }
}
