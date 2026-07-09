import AppKit
import StatusCore

// Headless mode: `StatusBar --check` runs one real refresh against the live
// status APIs, prints a summary, and exits. Useful for diagnostics and CI, and
// exercises the exact monitor pipeline the menubar uses.
if CommandLine.arguments.contains("--check") {
    let registry = AdapterRegistry.load(searchPaths: AdapterRegistry.defaultSearchPaths())
    let store = ConfigurationStore(defaultConfig: AppConfiguration(sites: registry.suggestedSites))
    let config = store.loadOrCreateDefault()
    let monitor = StatusMonitor(registry: registry)

    if registry.adapterIDs.isEmpty {
        print(
            "⚠️  No adapters loaded. Build them with `make adapters` or set STATUSBAR_ADAPTERS_DIR.")
    }

    let done = DispatchSemaphore(value: 0)
    // Detached so the work runs off the main thread — top-level code in an
    // executable is MainActor-isolated, and we block the main thread on the
    // semaphore below, which would otherwise deadlock a MainActor task.
    Task.detached {
        let results = await monitor.refresh(config: config)
        let now = Date()
        let threshold: TimeInterval =
            config.demoteStaleIssues
            ? TimeInterval(max(1, config.staleIssueThresholdHours) * 3600)
            : .greatestFiniteMagnitude
        let symbol: (StatusLevel) -> String = {
            switch $0 {
            case .major: return "🔴"
            case .minor: return "🟠"
            case .operational: return "⚪️"
            case .unknown: return "❔"
            }
        }
        let overall = results.overallLevel(threshold: threshold, now: now)
        print("Overall: \(symbol(overall)) \(overall.rawValue)")
        for status in results {
            // Per-site row mirrors the menu: honest to the source's own level.
            print(
                "  \(symbol(status.level)) \(status.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(status.detail)"
            )
            let (fresh, stale) = status.partitionedIssues(threshold: threshold, now: now)
            for issue in fresh {
                let age = issue.startedAt.map { " (started \(relativeAge($0)))" } ?? ""
                print("       ↳ \(issue.summary)\(age)")
            }
            // Demoted: lingering low-impact issues that have gone quiet. Shown
            // dimmed so it's obvious what the menu now tucks into a submenu.
            for issue in stale {
                let quiet = issue.lastActivity.map { " (quiet since \(relativeAge($0)))" } ?? ""
                print("       · [low-priority] \(issue.summary)\(quiet)")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// List loaded adapters (built-in + user-installed) and their suggested sites.
if CommandLine.arguments.contains("--adapters") {
    let registry = AdapterRegistry.load(searchPaths: AdapterRegistry.defaultSearchPaths())
    print("User adapters folder: \(AdapterRegistry.userAdaptersDirectory.path)")
    if registry.adapterIDs.isEmpty {
        print("No adapters loaded.")
    } else {
        for id in registry.adapterIDs {
            let sites = registry.suggestedSites.filter { $0.adapterID == id }.map(\.name)
            print("  • \(id)  (suggests: \(sites.isEmpty ? "—" : sites.joined(separator: ", ")))")
        }
    }
    exit(0)
}

// Launch-at-login control from the command line (used for install/verify).
if CommandLine.arguments.contains("--login-status") {
    print("Launch at login: \(LoginItem.statusDescription)")
    exit(0)
}
if CommandLine.arguments.contains("--login-enable") {
    do { _ = try LoginItem.setEnabled(true) } catch { print("Failed: \(error)"); exit(1) }
    print("Launch at login: \(LoginItem.statusDescription)")
    exit(0)
}
if CommandLine.arguments.contains("--login-disable") {
    do { _ = try LoginItem.setEnabled(false) } catch { print("Failed: \(error)"); exit(1) }
    print("Launch at login: \(LoginItem.statusDescription)")
    exit(0)
}

// Menubar-only agent: no dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
