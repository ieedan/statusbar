import XCTest

@testable import StatusCore

/// Main-actor-bound: `FileWatcher` delivers callbacks there, so the waits below
/// must spin the run loop rather than block it — a sleeping main thread would
/// starve the very callbacks these tests are waiting on.
@MainActor
final class FileWatcherTests: XCTestCase {
    // XCTest's setUp/tearDown hooks are nonisolated, so these can't be
    // main-actor state. XCTest runs setup, the test body, and teardown serially
    // on one thread, so unchecked access is safe here.
    private nonisolated(unsafe) var directory: URL!
    private nonisolated(unsafe) var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("config.json")
        try Data("one".utf8).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Advances time while still servicing main-actor work.
    private func spin(_ interval: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }

    /// Lets the watcher open its descriptor before the first write, so the
    /// write doesn't land in the gap between `init` and arming.
    private func waitForArm() { spin(0.3) }

    func testReportsInPlaceWrite() throws {
        let fired = expectation(description: "callback fired")
        let watcher = FileWatcher(url: fileURL, debounce: 0.05) { fired.fulfill() }
        defer { watcher.stop() }
        waitForArm()

        try Data("two".utf8).write(to: fileURL)

        wait(for: [fired], timeout: 5)
    }

    /// The case that motivates re-arming: `Data.write(options: .atomic)` swaps
    /// in a new inode, so a watcher that kept following the original descriptor
    /// would report the first replace and then go permanently deaf. This is how
    /// `ConfigurationStore.save` writes, so it's the common path in practice.
    func testKeepsReportingAcrossAtomicReplacements() throws {
        let fired = expectation(description: "callback fired for each replace")
        fired.expectedFulfillmentCount = 3
        let watcher = FileWatcher(url: fileURL, debounce: 0.05) { fired.fulfill() }
        defer { watcher.stop() }
        waitForArm()

        for round in 0..<3 {
            try Data("replace-\(round)".utf8).write(to: fileURL, options: .atomic)
            // Comfortably longer than the debounce, so each replace is its own
            // callback instead of being coalesced with the next.
            spin(0.4)
        }

        wait(for: [fired], timeout: 10)
    }

    /// A burst of writes should wake the app once, not once per write.
    func testCoalescesBurstIntoSingleCallback() throws {
        let counter = Counter()
        let watcher = FileWatcher(url: fileURL, debounce: 0.3) { counter.increment() }
        defer { watcher.stop() }
        waitForArm()

        for round in 0..<5 {
            try Data("burst-\(round)".utf8).write(to: fileURL)
            spin(0.02)
        }
        spin(1.5)

        XCTAssertEqual(counter.value, 1)
    }

    /// Watching may start before the file exists (first run seeds it a moment
    /// later); the watcher should pick it up once it appears.
    func testArmsOnceAMissingFileAppears() throws {
        let missing = directory.appendingPathComponent("later.json")
        let fired = expectation(description: "callback fired")
        let watcher = FileWatcher(url: missing, debounce: 0.05) { fired.fulfill() }
        defer { watcher.stop() }

        try Data("created".utf8).write(to: missing)
        // Outlast one retry interval so the watcher has armed on the new file.
        spin(3)
        try Data("modified".utf8).write(to: missing)

        wait(for: [fired], timeout: 10)
    }

    func testStopSilencesFurtherChanges() throws {
        let counter = Counter()
        let watcher = FileWatcher(url: fileURL, debounce: 0.05) { counter.increment() }
        waitForArm()
        watcher.stop()
        spin(0.3)

        try Data("after-stop".utf8).write(to: fileURL)
        spin(1.0)

        XCTAssertEqual(counter.value, 0)
    }
}

/// Tally for callbacks. Main-actor-isolated (so implicitly `Sendable`), matching
/// where `FileWatcher` invokes its callback.
@MainActor
private final class Counter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
