import AppKit
import StatusCore

/// A table view that offers a per-row context menu on right-click.
final class ServiceTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenuProvider?(row)
    }
}

/// Settings window: enable/disable and reorder monitored services.
///
/// The list shows every known service (configured sites + all adapter
/// suggestions); the per-row checkbox is the only add/remove control, so there
/// are no +/- buttons. Reordering (drag rows) lives here because the menubar
/// dropdown itself is an `NSMenu`, which can't host drags. Every edit is
/// persisted immediately and `onChange` fires so the menubar refreshes.
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigurationStore
    private var registry: AdapterRegistry
    private let onChange: () -> Void
    private let reloadAdapters: () -> AdapterRegistry

    private var sites: [SiteConfig] = []
    private var refreshIntervalSeconds = 60
    private var tableView: ServiceTableView!
    private var loginCheckbox: NSButton!

    private let dragType = NSPasteboard.PasteboardType("dev.statusbar.service.row")

    init(store: ConfigurationStore,
         registry: AdapterRegistry,
         onChange: @escaping () -> Void,
         reloadAdapters: @escaping () -> AdapterRegistry) {
        self.store = store
        self.registry = registry
        self.onChange = onChange
        self.reloadAdapters = reloadAdapters

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Site Status — Settings"
        window.center()
        super.init(window: window)

        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Adopt a registry rebuilt elsewhere (e.g. after a menu-bar "Reload Config
    /// & Refresh"), so newly-suggested services appear in the list.
    func updateRegistry(_ registry: AdapterRegistry) {
        self.registry = registry
        reload()
    }

    /// Reload from disk (call before showing, in case the file changed).
    func reload() {
        let config = store.loadOrCreateDefault()
        sites = Self.merged(configured: config.sites, suggestions: registry.suggestedSites)
        refreshIntervalSeconds = config.refreshIntervalSeconds
        tableView?.reloadData()
        loginCheckbox?.state = LoginItem.isEnabled ? .on : .off
    }

    /// The list shows every known service. The user's configured sites come
    /// first (preserving their order and enabled state); any adapter-suggested
    /// site not yet configured is appended, disabled, so the user opts in with
    /// the checkbox. This is why there are no add/remove buttons.
    private static func merged(configured: [SiteConfig], suggestions: [SiteConfig]) -> [SiteConfig] {
        var result = configured
        let taken = Set(configured.map(\.id))
        for suggestion in suggestions where !taken.contains(suggestion.id) {
            var entry = suggestion
            entry.enabled = false
            result.append(entry)
        }
        return result
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let table = ServiceTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([dragType])
        table.contextMenuProvider = { [weak self] row in self?.contextMenu(for: row) }

        let enabledCol = NSTableColumn(identifier: .init("enabled"))
        enabledCol.title = "On"
        enabledCol.width = 34
        enabledCol.maxWidth = 34
        table.addTableColumn(enabledCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Service"
        nameCol.width = 150
        table.addTableColumn(nameCol)

        let urlCol = NSTableColumn(identifier: .init("url"))
        urlCol.title = "Status URL"
        urlCol.width = 320
        table.addTableColumn(urlCol)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.tableView = table

        // Bottom bar: a hint plus the Adapters and Launch-at-login controls.
        // Services are added/removed purely via each row's checkbox — every known
        // service is always listed, so there are no +/- buttons.
        let adaptersButton = NSButton(title: "Adapters…", target: self, action: #selector(showAdaptersMenu(_:)))
        adaptersButton.bezelStyle = .rounded
        adaptersButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Check a service to show it · drag to reorder")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let loginCheck = NSButton(checkboxWithTitle: "Launch at login",
                                  target: self, action: #selector(toggleLoginItem(_:)))
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        self.loginCheckbox = loginCheck

        let bar = NSStackView(views: [hint, spacer, adaptersButton, loginCheck])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let site = sites[row]
        switch tableColumn?.identifier.rawValue {
        case "enabled":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            check.state = site.enabled ? .on : .off
            return check
        case "name":
            return cell(text: site.name, secondary: false)
        default:
            return cell(text: site.url.absoluteString, secondary: true)
        }
    }

    private func cell(text: String, secondary: Bool) -> NSTableCellView {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: secondary ? 11 : 13)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.pasteboardItems?.first?.string(forType: dragType),
              let source = Int(str) else { return false }
        var dest = row
        let moved = sites.remove(at: source)
        if source < dest { dest -= 1 }
        sites.insert(moved, at: dest)
        tableView.reloadData()
        persist()
        return true
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard sites.indices.contains(row) else { return }
        sites[row].enabled = (sender.state == .on)
        persist()
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard sites.indices.contains(row) else { return nil }
        let site = sites[row]
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: site.enabled ? "Disable" : "Enable",
            action: #selector(contextToggle(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = row
        menu.addItem(toggle)

        let open = NSMenuItem(title: "Open Status Page", action: #selector(contextOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = row
        menu.addItem(open)

        return menu
    }

    @objc private func contextToggle(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, sites.indices.contains(row) else { return }
        sites[row].enabled.toggle()
        tableView.reloadData()
        persist()
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, sites.indices.contains(row) else { return }
        NSWorkspace.shared.open(sites[row].url)
    }

    // MARK: - Launch at login

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            let enabled = try LoginItem.setEnabled(sender.state == .on)
            sender.state = enabled ? .on : .off
        } catch {
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn't change launch-at-login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Adapters (install / reveal)

    @objc private func showAdaptersMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let loaded = NSMenuItem(
            title: "Loaded: \(registry.adapterIDs.isEmpty ? "none" : registry.adapterIDs.joined(separator: ", "))",
            action: nil, keyEquivalent: "")
        loaded.isEnabled = false
        menu.addItem(loaded)
        menu.addItem(.separator())

        let install = NSMenuItem(title: "Install Adapter…", action: #selector(installAdapter), keyEquivalent: "")
        install.target = self
        menu.addItem(install)

        let reveal = NSMenuItem(title: "Reveal Adapters Folder", action: #selector(revealAdaptersFolder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func installAdapter() {
        let panel = NSOpenPanel()
        panel.title = "Install Adapter"
        panel.message = "Choose an adapter .js file (or an adapter folder containing adapter.json)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        do {
            try copyInAdapter(from: source)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't install adapter"
            alert.informativeText = (error as? AdapterInstallError)?.message ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private enum AdapterInstallError: Error {
        case notJavaScript
        case invalidScript(String)

        var message: String {
            switch self {
            case .notJavaScript:
                return "Select a .js file or an adapter folder."
            case .invalidScript(let detail):
                return "That file isn't a valid adapter.\n\n\(detail)"
            }
        }
    }

    private func copyInAdapter(from source: URL) throws {
        let fm = FileManager.default
        let destDir = AdapterRegistry.userAdaptersDirectory
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if !isDirectory {
            guard source.pathExtension == "js" else { throw AdapterInstallError.notJavaScript }
            // Validate before copying so bad files are rejected with a clear reason.
            let script = try String(contentsOf: source, encoding: .utf8)
            do { _ = try JSAdapter(script: script) }
            catch { throw AdapterInstallError.invalidScript("\(error)") }
        }

        let target = destDir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)

        // Rebuild the registry app-wide, then re-merge so any newly-suggested
        // sites appear as (unchecked) rows in the list right away.
        let before = Set(registry.adapterIDs)
        registry = reloadAdapters()
        let added = registry.adapterIDs.filter { !before.contains($0) }
        reload()

        let alert = NSAlert()
        alert.messageText = "Adapter installed"
        if added.isEmpty {
            alert.informativeText = "Copied \"\(source.lastPathComponent)\". No new adapter id appeared — it may replace an existing one or failed to load."
        } else {
            alert.informativeText = "Added: \(added.joined(separator: ", ")). Its suggested sites are now in the list — check one to show it."
        }
        alert.runModal()
    }

    @objc private func revealAdaptersFolder() {
        let dir = AdapterRegistry.userAdaptersDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: - Persistence

    private func persist() {
        let config = AppConfiguration(refreshIntervalSeconds: refreshIntervalSeconds, sites: sites)
        try? store.save(config)
        onChange()
    }
}
