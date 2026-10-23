import Foundation

/// Watches a single file and reports changes, coalescing rapid bursts into one
/// callback delivered on the main actor.
///
/// Re-arms itself when the file is *replaced* rather than modified in place.
/// `ConfigurationStore.save` writes atomically (temp file, then `rename` over
/// the target), which swaps in a new inode; a descriptor-based watch keeps
/// following the old, now-unlinked one, so without re-arming the watcher goes
/// deaf after the first save.
public final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable @MainActor () -> Void

    /// Serializes all access to the mutable state below.
    private let queue = DispatchQueue(label: "dev.statusbar.file-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pendingCallback: DispatchWorkItem?
    private var stopped = false

    /// How long to wait for the file to exist before retrying, when the path
    /// isn't there yet at arm time.
    private static let missingFileRetry: TimeInterval = 2

    public init(
        url: URL,
        debounce: TimeInterval = 0.25,
        onChange: @escaping @Sendable @MainActor () -> Void
    ) {
        self.url = url
        self.debounceInterval = debounce
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    deinit {
        source?.cancel()
        pendingCallback?.cancel()
    }

    /// Stops watching. Safe to call more than once.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pendingCallback?.cancel()
            self.pendingCallback = nil
            self.source?.cancel()
            self.source = nil
        }
    }

    /// Opens the file and starts a fresh watch. Must run on `queue`.
    private func arm() {
        guard !stopped else { return }
        source?.cancel()
        source = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Not there yet — e.g. watching started before first-run seeding
            // wrote the file. Keep trying so it's picked up once it appears.
            queue.asyncAfter(deadline: .now() + Self.missingFileRetry) { [weak self] in
                self?.arm()
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let flags = self.source?.data else { return }
            // A delete or rename means this descriptor now watches an inode
            // nothing will ever write to again — reopen the path.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.arm()
            }
            self.scheduleCallback()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Collapses a burst of events into a single callback. One save can easily
    /// produce several — an editor truncates then writes, an atomic replace
    /// fires both a delete and a write — and the delay also gives a
    /// partially-written file time to land before anyone reads it.
    private func scheduleCallback() {
        pendingCallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let callback = self.onChange
            Task { @MainActor in callback() }
        }
        pendingCallback = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
