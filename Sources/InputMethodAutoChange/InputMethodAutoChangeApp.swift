import AppKit

/// Wires the whole pipeline together: settings → Tier 1/2 checkers →
/// `DecisionEngine` → `KeyEventTapManager`, plus the menu-bar UI. This is the
/// only place that constructs concrete dependencies; everything downstream
/// of here takes them via `init`.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyEventTapManager: KeyEventTapManager?
    private var settingsWindowController: SettingsWindowController?
    private var statusBarController: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon / app switcher entry — belt-and-suspenders with
        // Info.plist's LSUIElement.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared

        let judge: PlausibilityJudge?
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            judge = FoundationModelsJudge()
        } else {
            judge = nil
        }
        #else
        judge = nil
        #endif

        let dictionaryChecker = CombinedWordChecker(checkers: [
            SpellCheckerWordChecker(),
            UserDictionaryWordChecker(settings: settings),
        ])
        let decisionEngine = DecisionEngine(dictionaryChecker: dictionaryChecker, judge: judge)

        let tapManager = KeyEventTapManager(settings: settings, decisionEngine: decisionEngine)
        keyEventTapManager = tapManager

        let settingsWindowController = SettingsWindowController(settings: settings)
        self.settingsWindowController = settingsWindowController
        // Retry starting the tap every time the Permissions section's status
        // is (re-)checked -- covers both the window's own polling while it's
        // open, and the one-shot check right after launch below. `start()`
        // is a no-op if it's already running.
        settingsWindowController.onPermissionStatusRefresh = { [weak tapManager] in
            tapManager?.start() ?? false
        }

        let statusBarController = StatusBarController(settings: settings, settingsWindowController: settingsWindowController)
        self.statusBarController = statusBarController
        // "Show in the menu bar" needs to take effect immediately, not just
        // after a relaunch.
        settingsWindowController.onMenuBarVisibilityChanged = { [weak statusBarController] in
            statusBarController?.updateVisibility()
        }

        let accessibilityGranted = PermissionsManager.isAccessibilityTrusted(prompt: false)

        if !accessibilityGranted {
            // First run (or the permission was revoked): walk the user
            // through it rather than silently doing nothing. Triggers the
            // OS's own consent prompt, then opens Settings (which now also
            // holds Permissions) so they can see the status update live.
            _ = PermissionsManager.isAccessibilityTrusted(prompt: true)
            settingsWindowController.show()
        }

        if !tapManager.start() {
            DebugLogger.log("failed to create the event tap — check Accessibility permission in System Settings.")
            // AXIsProcessTrusted can briefly report an old grant after an
            // ad-hoc-signed rebuild even though CGEventTap creation is
            // rejected for the new binary identity. Don't leave the utility
            // silently running but inert: surface Settings and request the
            // current build's permission so its polling can retry start().
            _ = PermissionsManager.isAccessibilityTrusted(prompt: true)
            settingsWindowController.show()
        }
    }

    /// With no Dock icon and possibly no menu bar icon either (if "Show in
    /// the menu bar" is off), there'd otherwise be no way back into
    /// Settings short of quitting and relaunching. Re-launching the already-
    /// running app (e.g. from Spotlight) sends this instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindowController?.show()
        return true
    }
}
