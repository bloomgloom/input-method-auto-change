import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService`, which is the current (macOS 13+) way
/// for a standalone .app to register/unregister itself as a login item
/// without a separate helper app. No own persistence needed -- the OS
/// already tracks this registration, so `isEnabled` just reflects it live.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("InputMethodAutoChange: failed to \(enabled ? "register" : "unregister") launch-at-login: \(error)")
            return false
        }
    }
}
