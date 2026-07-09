import AppKit
import StatusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = StatusMonitor()
    private let configStore = ConfigurationStore()

    private var config = AppConfiguration.default
    private var results: [SiteStatus] = []
    private var lastChecked: Date?
    private var isRefreshing = false
    private var refreshTimer: Timer?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = configStore.loadOrCreateDefault()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcons.shape(for: .unknown, filled: false, size: 15)
        statusItem.button?.toolTip = "Site Status"
        statusItem.menu = NSMenu()

        rebuildMenu()
        scheduleTimer()
        refresh()
    }

    // MARK: - Refresh

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(15, config.refreshIntervalSeconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
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
        let overall = results.overallLevel
        statusItem.button?.image = StatusIcons.shape(for: overall, filled: false, size: 15)
        statusItem.button?.toolTip = "Site Status — \(StatusIcons.label(for: overall))"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let overall = results.overallLevel

        let summary = NSMenuItem(title: StatusIcons.label(for: overall), action: nil, keyEquivalent: "")
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

                // Indented detail line per active issue affecting this site,
                // capped so a single busy service can't dominate the menu.
                for issue in status.issues.prefix(Self.maxIssuesPerSite) {
                    let detail = NSMenuItem(title: Self.truncated(issue.summary), action: nil, keyEquivalent: "")
                    detail.indentationLevel = 2
                    detail.isEnabled = false
                    detail.toolTip = issue.summary
                    menu.addItem(detail)
                }
                let overflow = status.issues.count - Self.maxIssuesPerSite
                if overflow > 0 {
                    let more = NSMenuItem(title: "+\(overflow) more…", action: #selector(openSite(_:)), keyEquivalent: "")
                    more.target = self
                    more.representedObject = status.pageURL
                    more.indentationLevel = 2
                    menu.addItem(more)
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
        add(menu, "Quit Site Status", #selector(quit), key: "q")

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
        if settingsController == nil {
            settingsController = SettingsWindowController(store: configStore) { [weak self] in
                self?.applyConfigChange()
            }
        }
        settingsController?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Called after Settings edits the config: reload it and re-check.
    private func applyConfigChange() {
        config = configStore.loadOrCreateDefault()
        scheduleTimer()
        refresh()
    }

    @objc private func revealConfig() {
        config = configStore.loadOrCreateDefault()
        NSWorkspace.shared.activateFileViewerSelecting([configStore.fileURL])
    }

    @objc private func reloadConfig() {
        do {
            config = try configStore.load()
            scheduleTimer()
            refresh()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't load configuration"
            alert.informativeText = "The config file is missing or contains invalid JSON.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    /// Longest a menu row's text may be before it's clipped with an ellipsis.
    /// Keeps the menu from stretching to fit a wordy incident; the full text
    /// stays available in the row's tooltip.
    private static let maxRowLength = 56

    /// Most issue rows to show under one service before collapsing to "+N more".
    private static let maxIssuesPerSite = 5

    private static func truncated(_ text: String) -> String {
        guard text.count > maxRowLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxRowLength)
        return text[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}
