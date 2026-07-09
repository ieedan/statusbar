import Foundation

/// User-editable app configuration, persisted as JSON.
public struct AppConfiguration: Codable, Sendable, Equatable {
    /// How often to re-check every site, in seconds.
    public var refreshIntervalSeconds: Int
    /// The sites to monitor.
    public var sites: [SiteConfig]

    public init(refreshIntervalSeconds: Int = 60, sites: [SiteConfig]) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.sites = sites
    }
}

/// Loads and saves `AppConfiguration` to disk, seeding defaults on first run.
public struct ConfigurationStore: Sendable {
    public let fileURL: URL
    /// Written to disk on first run (or when the file is unreadable). Callers
    /// build this from the loaded adapters' suggested sites.
    private let defaultConfig: AppConfiguration

    /// Default location: `~/Library/Application Support/StatusBar/config.json`.
    public init(defaultConfig: AppConfiguration, fileURL: URL? = nil) {
        self.defaultConfig = defaultConfig
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL =
                base
                .appendingPathComponent("StatusBar", isDirectory: true)
                .appendingPathComponent("config.json")
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Loads config from disk, writing (and returning) defaults if none exists
    /// or the existing file is unreadable.
    public func loadOrCreateDefault() -> AppConfiguration {
        if let data = try? Data(contentsOf: fileURL),
            let config = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        {
            return config
        }
        try? save(defaultConfig)
        return defaultConfig
    }

    /// Loads config, throwing on a malformed file (used when the user hits "Reload").
    public func load() throws -> AppConfiguration {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    public func save(_ config: AppConfiguration) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
