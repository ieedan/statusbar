import AppKit
import StatusCore

// Headless mode: `StatusBar --check` runs one real refresh against the live
// status APIs, prints a summary, and exits. Useful for diagnostics and CI, and
// exercises the exact monitor pipeline the menubar uses.
if CommandLine.arguments.contains("--check") {
    let store = ConfigurationStore()
    let config = store.loadOrCreateDefault()
    let monitor = StatusMonitor()

    let done = DispatchSemaphore(value: 0)
    // Detached so the work runs off the main thread — top-level code in an
    // executable is MainActor-isolated, and we block the main thread on the
    // semaphore below, which would otherwise deadlock a MainActor task.
    Task.detached {
        let results = await monitor.refresh(config: config)
        let symbol: (StatusLevel) -> String = {
            switch $0 {
            case .major: return "🔴"
            case .minor: return "🟠"
            case .operational: return "⚪️"
            case .unknown: return "❔"
            }
        }
        print("Overall: \(symbol(results.overallLevel)) \(results.overallLevel.rawValue)")
        for status in results {
            print("  \(symbol(status.level)) \(status.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(status.detail)")
            for issue in status.issues {
                print("       ↳ \(issue.summary)")
            }
        }
        done.signal()
    }
    done.wait()
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
