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

/// Settings window: add, remove, reorder, and enable/disable monitored services.
///
/// Reordering (drag rows) and removal (right-click, or the − button) live here
/// because the menubar dropdown itself is an `NSMenu`, which can't host drags or
/// contextual menus. Every edit is persisted immediately and `onChange` fires so
/// the menubar refreshes.
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

    /// Reload from disk (call before showing, in case the file changed).
    func reload() {
        let config = store.loadOrCreateDefault()
        sites = config.sites
        refreshIntervalSeconds = config.refreshIntervalSeconds
        tableView?.reloadData()
        loginCheckbox?.state = LoginItem.isEnabled ? .on : .off
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

        // Bottom bar: +/- and a hint.
        let addButton = NSButton(title: "+", target: self, action: #selector(showAddMenu(_:)))
        addButton.bezelStyle = .smallSquare
        addButton.setButtonType(.momentaryPushIn)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let removeButton = NSButton(title: "−", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .smallSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let adaptersButton = NSButton(title: "Adapters…", target: self, action: #selector(showAdaptersMenu(_:)))
        adaptersButton.bezelStyle = .rounded
        adaptersButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Drag to reorder · right-click a row for options")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let loginCheck = NSButton(checkboxWithTitle: "Launch at login",
                                  target: self, action: #selector(toggleLoginItem(_:)))
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        self.loginCheckbox = loginCheck

        let bar = NSStackView(views: [addButton, removeButton, hint, spacer, adaptersButton, loginCheck])
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

    @objc private func removeSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { NSSound.beep(); return }
        for index in rows.sorted(by: >) where sites.indices.contains(index) {
            sites.remove(at: index)
        }
        tableView.reloadData()
        persist()
    }

    private func remove(row: Int) {
        guard sites.indices.contains(row) else { return }
        sites.remove(at: row)
        tableView.reloadData()
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

        menu.addItem(.separator())

        let remove = NSMenuItem(title: "Remove", action: #selector(contextRemove(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = row
        menu.addItem(remove)

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

    @objc private func contextRemove(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        remove(row: row)
    }

    // MARK: - Adding services

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let taken = Set(sites.map(\.id))
        for entry in registry.suggestedSites where !taken.contains(entry.id) {
            let item = NSMenuItem(title: entry.name, action: #selector(addCatalogService(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "All known services added", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Add Custom…", action: #selector(addCustomService), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func addCatalogService(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SiteConfig else { return }
        sites.append(entry)
        tableView.reloadData()
        persist()
    }

    @objc private func addCustomService() {
        let alert = NSAlert()
        alert.messageText = "Add a Service"
        alert.informativeText = "Enter a name, its base URL, and the adapter that reads it."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 62, width: 320, height: 24))
        nameField.placeholderString = "Name"
        let urlField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        urlField.placeholderString = "https://status.example.com"

        let adapterPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let ids = registry.adapterIDs
        adapterPopup.addItems(withTitles: ids)
        if let statuspageIndex = ids.firstIndex(of: "statuspage") {
            adapterPopup.selectItem(at: statuspageIndex)
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        accessory.addSubview(nameField)
        accessory.addSubview(urlField)
        accessory.addSubview(adapterPopup)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let adapterID = adapterPopup.titleOfSelectedItem ?? "statuspage"
        guard !name.isEmpty, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            let err = NSAlert()
            err.messageText = "Invalid service"
            err.informativeText = "A name and a valid http(s) URL are required."
            err.runModal()
            return
        }

        let id = Self.slug(name, existing: sites.map(\.id))
        sites.append(SiteConfig(id: id, name: name, adapterID: adapterID, url: url))
        tableView.reloadData()
        persist()
    }

    /// A stable, unique id derived from a display name.
    private static func slug(_ name: String, existing: [String]) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var candidate = base.isEmpty ? "service" : base
        var n = 2
        let taken = Set(existing)
        while taken.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
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

        // Rebuild the registry app-wide and reflect new suggested sites here.
        let before = Set(registry.adapterIDs)
        registry = reloadAdapters()
        let added = registry.adapterIDs.filter { !before.contains($0) }
        tableView.reloadData()

        let alert = NSAlert()
        alert.messageText = "Adapter installed"
        if added.isEmpty {
            alert.informativeText = "Copied \"\(source.lastPathComponent)\". No new adapter id appeared — it may replace an existing one or failed to load."
        } else {
            alert.informativeText = "Added: \(added.joined(separator: ", ")). Any suggested sites are now in the + menu."
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
