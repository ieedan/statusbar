import Foundation

/// Coordinates checking every configured site concurrently and returning a
/// normalized result set. UI-agnostic: the app layer schedules refreshes and
/// renders whatever this returns.
public actor StatusMonitor {
    private var providers: [ProviderKind: any StatusProvider]

    public init(providers: [any StatusProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    /// Convenience initializer wiring up the built-in providers backed by `fetcher`.
    public init(fetcher: HTTPFetching = URLSessionFetcher()) {
        self.init(providers: [
            StatuspageProvider(fetcher: fetcher),
            AWSHealthProvider(fetcher: fetcher),
        ])
    }

    /// Checks every enabled site in `config` concurrently. A site whose provider
    /// is missing or whose fetch fails yields an `.unknown` result rather than
    /// dropping out, so the UI always has one row per enabled site. Results are
    /// returned in the same order the sites appear in the config.
    public func refresh(config: AppConfiguration) async -> [SiteStatus] {
        let enabled = config.sites.filter(\.enabled)

        let results = await withTaskGroup(of: (Int, SiteStatus).self) { group in
            for (index, site) in enabled.enumerated() {
                group.addTask { [providers] in
                    (index, await Self.check(site: site, using: providers[site.kind]))
                }
            }
            var collected: [(Int, SiteStatus)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func check(site: SiteConfig, using provider: (any StatusProvider)?) async -> SiteStatus {
        guard let provider else {
            return SiteStatus(siteID: site.id, name: site.name, level: .unknown,
                              detail: "No provider for \(site.kind.rawValue)", checkedAt: Date(),
                              pageURL: site.url)
        }
        do {
            return try await provider.fetchStatus(for: site)
        } catch {
            return SiteStatus(siteID: site.id, name: site.name, level: .unknown,
                              detail: "Unavailable", checkedAt: Date(), pageURL: site.url)
        }
    }
}
