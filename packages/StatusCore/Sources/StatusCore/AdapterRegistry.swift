import Foundation

/// Loads adapters from disk and indexes them by id. Also aggregates every
/// adapter's `suggestedSites`, which become the Settings "Add service" catalog —
/// so dropping in a new adapter automatically contributes its suggested sites.
public final class AdapterRegistry: Sendable {
    private let byID: [String: JSAdapter]
    /// Adapter ids in load order.
    public let adapterIDs: [String]
    /// All suggested sites contributed by all loaded adapters, in load order.
    public let suggestedSites: [SiteConfig]

    public init(adapters: [JSAdapter]) {
        var map: [String: JSAdapter] = [:]
        var ids: [String] = []
        var suggested: [SiteConfig] = []
        for adapter in adapters {
            map[adapter.id] = adapter
            ids.append(adapter.id)
            suggested.append(contentsOf: adapter.suggestedSites)
        }
        self.byID = map
        self.adapterIDs = ids
        self.suggestedSites = suggested
    }

    public func adapter(id: String) -> JSAdapter? { byID[id] }

    // MARK: - Discovery

    private struct Manifest: Decodable {
        let id: String
        let entry: String
    }

    /// Where user-installed adapters live. A user can drop a single `.js` file
    /// (or an adapter folder) here — see `load`.
    public static var userAdaptersDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("StatusBar/adapters", isDirectory: true)
    }

    /// Directories searched for adapters, later paths overriding earlier ones:
    /// 1. bundled adapters in the app's Resources,
    /// 2. `STATUSBAR_ADAPTERS_DIR` (colon-separated) — used in development,
    /// 3. user-installed adapters in Application Support.
    public static func defaultSearchPaths() -> [URL] {
        var paths: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("adapters", isDirectory: true) {
            paths.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["STATUSBAR_ADAPTERS_DIR"] {
            for part in env.split(separator: ":") where !part.isEmpty {
                paths.append(URL(fileURLWithPath: String(part), isDirectory: true))
            }
        }
        paths.append(userAdaptersDirectory)
        return paths
    }

    /// Discover and load every adapter under `searchPaths`. An adapter is either:
    /// - a bare `*.js` file (the simplest form — no build, no manifest), or
    /// - a directory containing an `adapter.json` whose `entry` points at a JS
    ///   bundle (how the built-in adapters ship).
    ///
    /// Later search paths override earlier ones with the same id, so a user
    /// adapter can replace a built-in. Failures (script error, bad manifest) skip
    /// that adapter — a broken plugin can't take down the app.
    public static func load(searchPaths: [URL]) -> AdapterRegistry {
        let fm = FileManager.default
        var order: [String] = []
        var map: [String: JSAdapter] = [:]

        func register(_ adapter: JSAdapter) {
            if map[adapter.id] == nil { order.append(adapter.id) }
            map[adapter.id] = adapter
        }

        for base in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if let adapter = loadManifestAdapter(directory: url) { register(adapter) }
                } else if url.pathExtension == "js" {
                    if let script = try? String(contentsOf: url, encoding: .utf8),
                       let adapter = try? JSAdapter(script: script) {
                        register(adapter)
                    }
                }
            }
        }

        return AdapterRegistry(adapters: order.compactMap { map[$0] })
    }

    private static func loadManifestAdapter(directory: URL) -> JSAdapter? {
        let manifestURL = directory.appendingPathComponent("adapter.json")
        guard let mdata = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: mdata) else { return nil }
        let entryURL = directory.appendingPathComponent(manifest.entry)
        guard let script = try? String(contentsOf: entryURL, encoding: .utf8) else { return nil }
        return try? JSAdapter(script: script)
    }
}
