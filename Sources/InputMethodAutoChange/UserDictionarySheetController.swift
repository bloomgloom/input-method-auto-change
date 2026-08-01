import AppKit

/// The "User Dictionary" list, opened from Settings the same way
/// `ExceptionsSheetController` is: a single "Manage Dictionary…" button
/// there opens this as a sheet, rather than the word list living inline in
/// the main form. Presented with `NSWindow.beginSheet`, dismissed with the
/// "Done" button in the bottom-right corner.
final class UserDictionarySheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let contentWidth: CGFloat = 380

    private let settings: AppSettings
    private let tableView = NSTableView()
    private var entries: [UserDictionaryEntry] = []

    init(settings: AppSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 428, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "User Dictionary"
        super.init(window: window)
        buildUI()
        entries = settings.userDictionaryEntries
        tableView.reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let wordColumn = NSTableColumn(identifier: .init("word"))
        wordColumn.title = "Word"
        wordColumn.width = 250
        let enabledColumn = NSTableColumn(identifier: .init("enabled"))
        enabledColumn.title = "On"
        enabledColumn.width = 70

        tableView.style = .inset
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(wordColumn)
        tableView.addTableColumn(enabledColumn)

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

        let hint = NSTextField(wrappingLabelWithString: "Words here are always treated as recognized -- corrected to on sight, the same as a real dictionary word -- while their toggle is on.")
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
            addWord()
        } else {
            removeSelectedWord()
        }
    }

    @objc private func doneButtonClicked() {
        guard let sheetWindow = window, let parentWindow = sheetWindow.sheetParent else { return }
        parentWindow.endSheet(sheetWindow)
    }

    /// A single-field `NSAlert` prompt rather than a whole extra window --
    /// there's nothing to pick from the filesystem here, unlike
    /// `ExceptionsSheetController`'s app picker, just one word to type in.
    private func addWord() {
        let alert = NSAlert()
        alert.messageText = "Add Word"
        alert.informativeText = "This word will always be treated as recognized."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Word"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard let sheetWindow = window else { return }
        alert.beginSheetModal(for: sheetWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, let self else { return }

            var current = self.settings.userDictionaryEntries
            if let index = current.firstIndex(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
                current[index].isEnabled = true
            } else {
                current.append(UserDictionaryEntry(word: word, isEnabled: true))
            }
            self.settings.userDictionaryEntries = current
            self.reloadEntries()
        }
    }

    private func removeSelectedWord() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        var current = settings.userDictionaryEntries
        for index in selected.sorted(by: >) where index < current.count {
            current.remove(at: index)
        }
        settings.userDictionaryEntries = current
        reloadEntries()
    }

    @objc private func entryToggled(_ sender: NSSwitch) {
        var current = settings.userDictionaryEntries
        guard sender.tag < current.count else { return }
        current[sender.tag].isEnabled = (sender.state == .on)
        settings.userDictionaryEntries = current
        entries = current
    }

    private func reloadEntries() {
        entries = settings.userDictionaryEntries
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        if tableColumn?.identifier.rawValue == "enabled" {
            let container = NSView()
            let toggle = NSSwitch()
            toggle.state = entry.isEnabled ? .on : .off
            toggle.tag = row
            toggle.target = self
            toggle.action = #selector(entryToggled(_:))
            toggle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            ])
            return container
        }

        return NSTextField(labelWithString: entry.word)
    }
}
