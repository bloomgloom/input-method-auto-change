import AppKit
import UniformTypeIdentifiers

/// The "Exceptions" list, broken out of the main Settings window into its
/// own sheet -- opened from a single "Manage Exceptions…" button there
/// (`SettingsWindowController.openExceptionsSheet`) rather than living
/// inline, so the main form stays one row per setting. Presented with
/// `NSWindow.beginSheet`, dismissed with the "Done" button in the
/// bottom-right corner.
final class ExceptionsSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let contentWidth: CGFloat = 380

    private let settings: AppSettings
    private let tableView = NSTableView()
    private var exceptions: [AppException] = []

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 428, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Exceptions"
        super.init(window: window)
        buildUI()
        exceptions = settings.appExceptions
        tableView.reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let appColumn = NSTableColumn(identifier: .init("app"))
        appColumn.title = "App"
        appColumn.width = 250
        let excludedColumn = NSTableColumn(identifier: .init("excluded"))
        excludedColumn.title = "Excluded"
        excludedColumn.width = 70

        // `.inset` + no header + no scroll-view border/background is what
        // gives System Settings' Privacy & Security lists (e.g.
        // Accessibility) their rounded, boxed look -- rather than a plain
        // bordered table.
        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(excludedColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 200),
        ])

        // A single +/- segmented control (rather than two separate buttons)
        // is how Apple's own editable lists -- including this same
        // Privacy & Security-style list -- present add/remove.
        let addRemoveControl = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(addRemoveSegmentClicked)
        )
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.setWidth(24, forSegment: 0)
        addRemoveControl.setWidth(24, forSegment: 1)

        let hint = NSTextField(wrappingLabelWithString: "Apps here are skipped entirely -- even if a text field is focused -- while their \"Excluded\" toggle is on.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneButtonClicked))
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded

        let bottomRow = NSStackView(views: [NSView(), doneButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill

        let stack = NSStackView(views: [scrollView, addRemoveControl, hint, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func addRemoveSegmentClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            addException()
        } else {
            removeSelectedException()
        }
    }

    @objc private func doneButtonClicked() {
        guard let sheetWindow = window, let parentWindow = sheetWindow.sheetParent else { return }
        parentWindow.endSheet(sheetWindow)
    }

    private func addException() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var current = settings.appExceptions
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { continue }
            if let index = current.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
                current[index].isExcluded = true
            } else {
                let displayName = FileManager.default.displayName(atPath: url.path)
                current.append(AppException(bundleIdentifier: bundleIdentifier, displayName: displayName, isExcluded: true))
            }
        }
        settings.appExceptions = current
        reloadExceptions()
    }

    private func removeSelectedException() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        var current = settings.appExceptions
        for index in selected.sorted(by: >) where index < current.count {
            current.remove(at: index)
        }
        settings.appExceptions = current
        reloadExceptions()
    }

    @objc private func exceptionToggled(_ sender: NSSwitch) {
        var current = settings.appExceptions
        guard sender.tag < current.count else { return }
        current[sender.tag].isExcluded = (sender.state == .on)
        settings.appExceptions = current
        exceptions = current
    }

    private func reloadExceptions() {
        exceptions = settings.appExceptions
        tableView.reloadData()
    }

    private func resolveIcon(for bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        exceptions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < exceptions.count else { return nil }
        let exception = exceptions[row]

        if tableColumn?.identifier.rawValue == "excluded" {
            let container = NSView()
            let toggle = NSSwitch()
            toggle.state = exception.isExcluded ? .on : .off
            toggle.tag = row
            toggle.target = self
            toggle.action = #selector(exceptionToggled(_:))
            toggle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            ])
            return container
        }

        let imageView = NSImageView(image: resolveIcon(for: exception.bundleIdentifier))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: exception.displayName)

        let rowStack = NSStackView(views: [imageView, label])
        rowStack.orientation = .horizontal
        rowStack.spacing = 6
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        return rowStack
    }
}
