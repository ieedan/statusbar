import AppKit
import StatusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var registry: AdapterRegistry?
    private var monitor: StatusMonitor?
    private var configStore: ConfigurationStore?

    private var config = AppConfiguration(sites: [])
    private var results: [SiteStatus] = []
    private var lastChecked: Date?
    private var isRefreshing = false
    private var refreshTimer: Timer?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcons.shape(for: .unknown, filled: false, size: 15, template: true)
        statusItem.button?.toolTip = "StatusBar"
        statusItem.menu = NSMenu()
        rebuildMenu()

        // Load adapters off the main thread (evaluates JS), then start monitoring.
        Task { @MainActor in
            let registry = await Task.detached {
                AdapterRegistry.load(searchPaths: AdapterRegistry.defaultSearchPaths())
            }.value
            let store = ConfigurationStore(
                defaultConfig: AppConfiguration(sites: registry.suggestedSites))

            self.registry = registry
            self.configStore = store
            self.config = store.loadOrCreateDefault()
            self.monitor = StatusMonitor(registry: registry)

            self.scheduleTimer()
            self.refresh()
        }
    }

    // MARK: - Refresh

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(15, config.refreshIntervalSeconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard let monitor, !isRefreshing else { return }
        isRefreshing = true
        rebuildMenu()
        let snapshot = config
        Task { @MainActor in
            let fresh = await monitor.refresh(config: snapshot)
            self.results = fresh
            self.lastChecked = Date()
            self.isRefreshing = false
            self.render()
        }
    }

    // MARK: - Rendering

    private func render() {
        let overall = results.overallLevel(threshold: staleThreshold, now: Date())
        statusItem.button?.image = StatusIcons.shape(for: overall, filled: false, size: 15, template: true)
        statusItem.button?.toolTip = "StatusBar — \(StatusIcons.label(for: overall))"
        rebuildMenu()
    }

    /// How long a non-major issue may go quiet before it's demoted, as a
    /// duration — or "never" (an unreachable threshold) when demotion is off.
    private var staleThreshold: TimeInterval {
        config.demoteStaleIssues
            ? TimeInterval(max(1, config.staleIssueThresholdHours) * 3600)
            : .greatestFiniteMagnitude
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // We set every item's enabled state explicitly (informational rows are
        // disabled, actions carry a target), so turn off auto-enabling — it would
        // otherwise gray out a low-priority submenu whose children are all disabled.
        menu.autoenablesItems = false
        let now = Date()
        let threshold = staleThreshold
        let overall = results.overallLevel(threshold: threshold, now: now)

        let summary = NSMenuItem(
            title: StatusIcons.label(for: overall), action: nil, keyEquivalent: "")
        summary.image = StatusIcons.shape(for: overall)
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        if results.isEmpty {
            let loading = NSMenuItem(
                title: isRefreshing ? "Checking…" : "No sites configured",
                action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        } else {
            for status in results {
                // The site row stays honest to what the source reports — a green
                // dot next to "Minor Service Outage" would contradict itself. The
                // demotion instead shows up as the issue moving into the submenu,
                // and in the *menubar* icon settling back to green (see `render`).
                let fullTitle = "\(status.name) — \(status.detail)"
                let item = NSMenuItem(
                    title: Self.truncated(fullTitle),
                    action: #selector(openSite(_:)),
                    keyEquivalent: "")
                item.target = self
                item.image = StatusIcons.shape(for: status.level)
                item.representedObject = status.pageURL
                item.toolTip = fullTitle
                menu.addItem(item)

                let (fresh, stale) = status.partitionedIssues(threshold: threshold, now: now)

                // Indented detail line per active issue affecting this site,
                // capped so a single busy service can't dominate the menu.
                for issue in fresh.prefix(Self.maxIssuesPerSite) {
                    menu.addItem(Self.issueRow(issue, indent: 2))
                }
                let overflow = fresh.count - Self.maxIssuesPerSite
                if overflow > 0 {
                    let more = NSMenuItem(
                        title: "+\(overflow) more…", action: #selector(openSite(_:)),
                        keyEquivalent: "")
                    more.target = self
                    more.representedObject = status.pageURL
                    more.indentationLevel = 2
                    menu.addItem(more)
                }

                // Lingering low-impact issues that have gone quiet are tucked into
                // a submenu so they stay reachable without cluttering the site.
                if !stale.isEmpty {
                    let label = stale.count == 1
                        ? "1 low-priority issue…" : "\(stale.count) low-priority issues…"
                    let staleItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    staleItem.indentationLevel = 2
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    for issue in stale {
                        submenu.addItem(Self.issueRow(issue, indent: 0))
                    }
                    staleItem.submenu = submenu
                    menu.addItem(staleItem)
                }
            }
        }

        menu.addItem(.separator())

        let checkedTitle: String
        if isRefreshing {
            checkedTitle = "Refreshing…"
        } else if let lastChecked {
            checkedTitle = "Last checked \(Self.timeFormatter.string(from: lastChecked))"
        } else {
            checkedTitle = "Not checked yet"
        }
        let checked = NSMenuItem(title: checkedTitle, action: nil, keyEquivalent: "")
        checked.isEnabled = false
        menu.addItem(checked)

        add(menu, "Refresh Now", #selector(refreshNow), key: "r")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Reveal Config in Finder", #selector(revealConfig), key: "")
        add(menu, "Reload Config & Refresh", #selector(reloadConfig), key: "")
        menu.addItem(.separator())
        add(menu, "Quit StatusBar", #selector(quit), key: "q")

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openSite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshNow() { refresh() }

    @objc private func openSettings() {
        guard let configStore, let registry else { NSSound.beep(); return }
        if settingsController == nil {
            settingsController = SettingsWindowController(
                store: configStore,
                registry: registry,
                onChange: { [weak self] in self?.applyConfigChange() },
                reloadAdapters: { [weak self] in self?.reloadAdapters() ?? registry })
        }
        settingsController?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Called after Settings edits the config: reload it and re-check.
    private func applyConfigChange() {
        guard let configStore else { return }
        config = configStore.loadOrCreateDefault()
        scheduleTimer()
        refresh()
    }

    /// Called after Settings installs/removes an adapter: rebuild the registry
    /// (picking up newly-installed plugins) and re-check. Returns the new
    /// registry so Settings can refresh its suggested-site catalog.
    private func reloadAdapters() -> AdapterRegistry {
        let registry = AdapterRegistry.load(searchPaths: AdapterRegistry.defaultSearchPaths())
        self.registry = registry
        self.monitor = StatusMonitor(registry: registry)
        refresh()
        return registry
    }

    @objc private func revealConfig() {
        guard let configStore else { return }
        _ = configStore.loadOrCreateDefault()
        NSWorkspace.shared.activateFileViewerSelecting([configStore.fileURL])
    }

    @objc private func reloadConfig() {
        guard let configStore else { return }
        // Rescan the adapters directory too, so adapters dropped into the folder
        // (via "Reveal Adapters Folder") are picked up without relaunching. Keep
        // an open Settings window in sync so its + menu reflects the new catalog.
        let registry = AdapterRegistry.load(searchPaths: AdapterRegistry.defaultSearchPaths())
        self.registry = registry
        self.monitor = StatusMonitor(registry: registry)
        settingsController?.updateRegistry(registry)
        do {
            config = try configStore.load()
            scheduleTimer()
            refresh()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't load configuration"
            alert.informativeText =
                "The config file is missing or contains invalid JSON.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    /// Longest a menu row's text may be before it's clipped with an ellipsis.
    /// Keeps the menu from stretching to fit a wordy incident; the full text
    /// stays available in the row's tooltip.
    private static let maxRowLength = 44
    /// Issue detail rows clip tighter than site rows — they carry the widest
    /// text, and the full description stays in the tooltip.
    private static let maxIssueLength = 38

    /// Most issue rows to show under one service before collapsing to "+N more".
    private static let maxIssuesPerSite = 5

    /// Builds one indented, informational issue row: truncated summary with a
    /// relative age, and a tooltip carrying the full text plus start / last-update
    /// times when the source reports them.
    private static func issueRow(_ issue: SiteIssue, indent: Int) -> NSMenuItem {
        let age = issue.startedAt.map { "  ·  \(relativeAge($0))" } ?? ""
        let row = NSMenuItem(
            title: truncated(issue.summary, max: maxIssueLength) + age,
            action: nil, keyEquivalent: "")
        row.indentationLevel = indent
        row.isEnabled = false
        var tip = issue.summary
        if let started = issue.startedAt {
            tip += "\n\nStarted \(fullTimeFormatter.string(from: started))"
        }
        if let updated = issue.updatedAt {
            tip += "\nLast updated \(fullTimeFormatter.string(from: updated))"
        }
        row.toolTip = tip
        return row
    }

    private static func truncated(_ text: String, max: Int = maxRowLength) -> String {
        guard text.count > max else { return text }
        let end = text.index(text.startIndex, offsetBy: max)
        return text[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    private static let fullTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()
}
