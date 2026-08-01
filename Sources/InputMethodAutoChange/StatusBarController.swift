import AppKit

/// The app's only UI surface in normal operation: a menu-bar status item
/// with a link to settings (which holds the launch-at-login/menu-bar-
/// visibility toggles and permissions) and quit. No Dock icon
/// (`LSUIElement` in Info.plist handles that).
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let settingsWindowController: SettingsWindowController

    init(settings: AppSettings, settingsWindowController: SettingsWindowController) {
        self.settings = settings
        self.settingsWindowController = settingsWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "keyboard",
            accessibilityDescription: "Input Method Auto Change"
        )
        statusItem.isVisible = settings.showsInMenuBar
        buildMenu()
    }

    /// Called whenever Settings' "Show in the menu bar" checkbox changes, so
    /// the icon can appear/disappear live instead of only after a relaunch.
    func updateVisibility() {
        statusItem.isVisible = settings.showsInMenuBar
    }

    private func buildMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }
}
