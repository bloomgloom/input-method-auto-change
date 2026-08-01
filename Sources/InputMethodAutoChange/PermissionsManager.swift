import AppKit
import ApplicationServices
import Foundation

/// Requests/checks the TCC permission this app needs: Accessibility
/// (`AXIsProcessTrusted`), required to post synthetic keyboard events
/// (`CGEventPost`) system-wide and to run the `CGEventTap` this app uses to
/// observe/modify keystrokes.
///
/// Input Monitoring (`IOHIDCheckAccess`/`IOHIDRequestAccess`) was previously
/// requested here too, on the assumption the `CGEventTap` needed it. It
/// doesn't: this app's tap is a non-`.listenOnly` session tap (it can modify
/// events, e.g. swallowing the undo keystroke after a correction), and that
/// configuration only requires Accessibility. Empirically, corrections work
/// with Accessibility granted and Input Monitoring untouched -- and since
/// this app never calls an API that's actually gated by
/// `kTCCServiceListenEvent`, macOS never creates a row for it in the Input
/// Monitoring list at all, so `IOHIDRequestAccess` silently no-ops and
/// there's nothing to toggle in System Settings either. Removed rather than
/// kept as a dead UI element.
enum PermissionsManager {
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        openSystemSettingsPane(identifier: "Privacy_Accessibility")
    }

    private static func openSystemSettingsPane(identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(identifier)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
