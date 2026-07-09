import Foundation

/// Checks every configured site concurrently and returns normalized results.
/// For each site it looks up the adapter, asks it for the URL, fetches (in
/// Swift), then hands the body back to the adapter to parse.
public actor StatusMonitor {
    private let registry: AdapterRegistry
    private let fetcher: HTTPFetching

    public init(registry: AdapterRegistry, fetcher: HTTPFetching = URLSessionFetcher()) {
        self.registry = registry
        self.fetcher = fetcher
    }

    /// Checks every enabled site in `config` concurrently. A site whose adapter
    /// is missing or whose fetch/parse fails yields an `.unknown` result rather
    /// than dropping out, so the UI always has one row per enabled site. Results
    /// are returned in config order.
    public func refresh(config: AppConfiguration) async -> [SiteStatus] {
        let enabled = config.sites.filter(\.enabled)

        let results = await withTaskGroup(of: (Int, SiteStatus).self) { group in
            for (index, site) in enabled.enumerated() {
                group.addTask { [registry, fetcher] in
                    (index, await Self.check(site: site, registry: registry, fetcher: fetcher))
                }
            }
            var collected: [(Int, SiteStatus)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func check(site: SiteConfig, registry: AdapterRegistry, fetcher: HTTPFetching)
        async -> SiteStatus
    {
        guard let adapter = registry.adapter(id: site.adapterID) else {
            return unknown(site, "No adapter '\(site.adapterID)'")
        }
        do {
            let endpoint = try await adapter.endpoint(baseURL: site.url.absoluteString)
            guard let url = URL(string: endpoint) else { return unknown(site, "Invalid endpoint") }

            let (data, code) = try await fetcher.data(from: url)
            guard (200..<300).contains(code) else { return unknown(site, "HTTP \(code)") }

            let body = decodeResponseBody(data)
            let parsed = try await adapter.parse(body: body, baseURL: site.url.absoluteString)

            return SiteStatus(
                siteID: site.id,
                name: site.name,
                level: parsed.level,
                detail: parsed.detail,
                issues: parsed.issues.collapsed(),
                checkedAt: Date(),
                pageURL: site.url
            )
        } catch {
            return unknown(site, "Unavailable")
        }
    }

    private static func unknown(_ site: SiteConfig, _ detail: String) -> SiteStatus {
        SiteStatus(
            siteID: site.id, name: site.name, level: .unknown,
            detail: detail, checkedAt: Date(), pageURL: site.url)
    }
}
