import AppKit
import UniformTypeIdentifiers

/// A small colored dot (green/red) showing whether a permission is granted.
private final class StatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isGranted: Bool = false {
        didSet {
            layer?.backgroundColor = (isGranted ? NSColor.systemGreen : NSColor.systemRed).cgColor
        }
    }
}

/// A single settings window, laid out as a two-column form -- right-aligned
/// row labels on the left and controls (with explanatory text where useful)
/// on the right -- the same look as Apple's own Notes/Reminders/System
/// Settings preference panes, in place of both
/// the old `NSTabView` layout and a card-per-section one. Permissions used to
/// live in their own window (`PermissionsWindowController`, now removed),
/// and Enable/Launch at Login used to live as toggles in the menu-bar menu
/// (`StatusBarController`, now just Settings + Quit); folding all of it in
/// here means there's one place to land on both first run and later from the
/// menu bar.
final class SettingsWindowController: NSWindowController {
    /// Width of every wide content-column view (hint text) -- keeps the
    /// right column a consistent width the way the dropdowns/slider/hint
    /// text all share one width in System Settings-style panes.
    private static let contentWidth: CGFloat = 380

    private let settings: AppSettings

    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let showsInMenuBarCheckbox = NSButton(checkboxWithTitle: "Show in the menu bar", target: nil, action: nil)
    private let accessibilityDot = StatusDotView()
    private let modeControl = NSSegmentedControl(labels: ["Dictionary only", "Dictionary + AFM"], trackingMode: .selectOne, target: nil, action: nil)
    private let enableLogsCheckbox = NSButton(checkboxWithTitle: "Enable Logs", target: nil, action: nil)
    /// Kept alive only while its sheet is on screen -- opened fresh from
    /// `openExceptionsSheet` each time rather than built up front, since
    /// there's no need for it to exist while the main Settings window is
    /// just sitting there unopened.
    private var exceptionsSheetController: ExceptionsSheetController?
    /// Same reasoning as `exceptionsSheetController`, for the "User
    /// Dictionary" sheet.
    private var userDictionarySheetController: UserDictionarySheetController?
    private var pollTimer: Timer?

    /// Called after every permission status refresh (granted or not). The
    /// return value reports whether the event tap is actually running, so a
    /// stale TCC grant cannot misleadingly leave the status dot green.
    var onPermissionStatusRefresh: (() -> Bool)?

    /// Called right after the "Show in the menu bar" checkbox changes, so
    /// `StatusBarController` can hide/show its status item live without this
    /// window needing to know about it directly.
    var onMenuBarVisibilityChanged: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window
        )
        reloadFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reloadFromSettings()
        // The utility normally runs as an accessory app, but Settings is a
        // real user-facing window. Promote it while the window is open so it
        // appears in both the Dock and the Cmd+Tab app switcher.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Polls while visible since there's no notification for "the user
        // just granted Accessibility in System Settings" -- the only way to
        // notice is to keep re-checking.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    @objc private func windowWillClose() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        addGeneralRows(to: grid)
        addPermissionsRows(to: grid)
        addModeRows(to: grid)
        addExceptionsRows(to: grid)
        addUserDictionaryRows(to: grid)
        addDebugRows(to: grid)

        // Columns only exist once at least one row has been added.
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .leading

        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
        ])
    }

    /// Appends a labeled row (or, with `label: nil`, a continuation row
    /// under the previous label -- e.g. hint text under a control) to the
    /// shared two-column form grid.
    private func addRow(to grid: NSGridView, label labelText: String?, content: NSView) {
        let labelView: NSView
        if let labelText {
            let field = NSTextField(labelWithString: labelText)
            field.font = .systemFont(ofSize: 13)
            labelView = field
        } else {
            labelView = NSGridCell.emptyContentView
        }
        let row = grid.addRow(with: [labelView, content])
        row.yPlacement = .center
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return hint
    }

    private func addGeneralRows(to grid: NSGridView) {
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        addRow(to: grid, label: "General", content: launchAtLoginCheckbox)

        showsInMenuBarCheckbox.target = self
        showsInMenuBarCheckbox.action = #selector(menuBarVisibilityToggled)
        addRow(to: grid, label: "Menu bar", content: showsInMenuBarCheckbox)
    }

    @objc private func launchAtLoginToggled() {
        let requestedState = launchAtLoginCheckbox.state == .on
        if !LaunchAtLogin.setEnabled(requestedState) {
            // Don't leave the UI claiming a state the OS rejected.
            launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func menuBarVisibilityToggled() {
        settings.showsInMenuBar = showsInMenuBarCheckbox.state == .on
        onMenuBarVisibilityChanged?()
    }

    private func addPermissionsRows(to grid: NSGridView) {
        accessibilityDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accessibilityDot.widthAnchor.constraint(equalToConstant: 10),
            accessibilityDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let requestButton = NSButton(title: "Request", target: self, action: #selector(requestAccessibility))
        let openButton = NSButton(title: "Open System Settings", target: self, action: #selector(openAccessibilitySettings))

        let row = NSStackView(views: [accessibilityDot, requestButton, openButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        addRow(to: grid, label: "Accessibility", content: row)
        addRow(to: grid, label: nil, content: hintLabel("Needed to watch keystrokes and correct them system-wide."))
    }

    private func addModeRows(to grid: NSGridView) {
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        addRow(to: grid, label: "Correction Mode", content: modeControl)
        addRow(to: grid, label: nil, content: hintLabel(
            "\"Dictionary + AFM\" also asks the on-device Apple Foundation Model about words the dictionary doesn't recognize (proper nouns, slang, coinages), and corrects them if it's confident. Dictionary-confirmed words never consult it either way."
        ))
    }

    /// Just a button that opens `ExceptionsSheetController` -- the list
    /// itself (with its add/remove controls) lives entirely in that sheet
    /// now, rather than inline here, so this row stays a single line like
    /// every other row in the form.
    private func addExceptionsRows(to grid: NSGridView) {
        let manageButton = NSButton(title: "Manage Exceptions…", target: self, action: #selector(openExceptionsSheet))
        addRow(to: grid, label: "Exceptions", content: manageButton)
        addRow(to: grid, label: nil, content: hintLabel(
            "Apps you add here are skipped entirely."
        ))
    }

    @objc private func openExceptionsSheet() {
        guard let parentWindow = window else { return }
        let sheetController = ExceptionsSheetController(settings: settings)
        exceptionsSheetController = sheetController
        parentWindow.beginSheet(sheetController.window!) { [weak self] _ in
            self?.exceptionsSheetController = nil
        }
    }

    /// Same as `addExceptionsRows` -- just a button that opens
    /// `UserDictionarySheetController`, which owns the actual word list.
    private func addUserDictionaryRows(to grid: NSGridView) {
        let manageButton = NSButton(title: "Manage Dictionary…", target: self, action: #selector(openUserDictionarySheet))
        addRow(to: grid, label: "User Dictionary", content: manageButton)
        addRow(to: grid, label: nil, content: hintLabel(
            "Words you add here are always treated as recognized."
        ))
    }

    @objc private func openUserDictionarySheet() {
        guard let parentWindow = window else { return }
        let sheetController = UserDictionarySheetController(settings: settings)
        userDictionarySheetController = sheetController
        parentWindow.beginSheet(sheetController.window!) { [weak self] _ in
            self?.userDictionarySheetController = nil
        }
    }

    /// A checkbox for whether `DebugLogger` writes to its file, plus a
    /// button that copies that file out to wherever the user picks --
    /// `log`/`log stream`/Console.app all proved unreliable for actually
    /// seeing this app's own messages, so this sidesteps them entirely.
    private func addDebugRows(to grid: NSGridView) {
        enableLogsCheckbox.target = self
        enableLogsCheckbox.action = #selector(enableLogsToggled)
        addRow(to: grid, label: "Debug", content: enableLogsCheckbox)

        let exportButton = NSButton(title: "Export Logs…", target: self, action: #selector(exportLogs))
        addRow(to: grid, label: nil, content: exportButton)
    }

    @objc private func enableLogsToggled() {
        settings.loggingEnabled = enableLogsCheckbox.state == .on
    }

    @objc private func exportLogs() {
        guard FileManager.default.fileExists(atPath: DebugLogger.logFileURL.path) else {
            let alert = NSAlert()
            alert.messageText = "No Logs Yet"
            alert.informativeText = "Turn on \"Enable Logs\" and reproduce the issue first -- there's nothing captured yet."
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder to export the log file to."
        guard panel.runModal() == .OK, let destinationDirectory = panel.urls.first else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = destinationDirectory.appendingPathComponent("InputMethodAutoChange-logs-\(formatter.string(from: Date())).log")

        do {
            try FileManager.default.copyItem(at: DebugLogger.logFileURL, to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Permissions

    private func refreshPermissionStatus() {
        let isTrusted = PermissionsManager.isAccessibilityTrusted(prompt: false)
        let isTapRunning = onPermissionStatusRefresh?() ?? isTrusted
        accessibilityDot.isGranted = isTrusted && isTapRunning
    }

    @objc private func requestAccessibility() {
        _ = PermissionsManager.isAccessibilityTrusted(prompt: true)
        refreshPermissionStatus()
    }

    @objc private func openAccessibilitySettings() {
        PermissionsManager.openAccessibilitySettings()
    }

    // MARK: - Loading/saving

    private func reloadFromSettings() {
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        showsInMenuBarCheckbox.state = settings.showsInMenuBar ? .on : .off
        refreshPermissionStatus()
        modeControl.selectedSegment = settings.llmCallMode == .dictionaryOnly ? 0 : 1
        enableLogsCheckbox.state = settings.loggingEnabled ? .on : .off
    }

    @objc private func modeChanged() {
        settings.llmCallMode = modeControl.selectedSegment == 0 ? .dictionaryOnly : .modelAssisted
    }
}
