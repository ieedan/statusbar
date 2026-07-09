import Foundation

/// Reads status from any Atlassian Statuspage instance via its public
/// `/api/v2/summary.json` endpoint. This covers the majority of large sites
/// (Vercel, GitHub, Cloudflare, Anthropic, OpenAI, and many more) and, unlike
/// `status.json`, also carries the active incidents and affected components used
/// to describe what specifically is broken.
public struct StatuspageProvider: StatusProvider {
    public let kind: ProviderKind = .statuspage
    private let fetcher: HTTPFetching

    public init(fetcher: HTTPFetching = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    private struct Summary: Decodable {
        struct Status: Decodable {
            let indicator: String
            let description: String
        }
        struct Component: Decodable {
            let name: String
            let status: String
        }
        struct Incident: Decodable {
            let name: String
            let impact: String
            let status: String
            let components: [Component]?
        }
        let status: Status
        let incidents: [Incident]?
        let components: [Component]?
    }

    public func fetchStatus(for site: SiteConfig) async throws -> SiteStatus {
        let endpoint = site.url.appendingPathComponent("api/v2/summary.json")
        let (data, code) = try await fetcher.data(from: endpoint)
        guard (200..<300).contains(code) else { throw ProviderError.badResponse(status: code) }
        guard !data.isEmpty else { throw ProviderError.emptyBody }

        let summary: Summary
        do {
            summary = try JSONDecoder().decode(Summary.self, from: data)
        } catch {
            throw ProviderError.decoding("\(error)")
        }

        return SiteStatus(
            siteID: site.id,
            name: site.name,
            level: Self.level(forIndicator: summary.status.indicator),
            detail: summary.status.description,
            issues: Self.issues(from: summary).collapsed(),
            checkedAt: Date(),
            pageURL: site.url
        )
    }

    /// Builds the per-issue detail lines. Unresolved incidents are the primary
    /// signal (one line per affected component, e.g. `Actions — Delays starting
    /// Actions runs`); if there are none but components are degraded, those are
    /// surfaced instead so a non-green status always has an explanation.
    private static func issues(from summary: Summary) -> [SiteIssue] {
        var issues: [SiteIssue] = []

        for incident in summary.incidents ?? [] where incident.status != "resolved" {
            let level = Self.level(forIndicator: incident.impact)
            let affected = incident.components ?? []
            if affected.isEmpty {
                issues.append(SiteIssue(component: nil, title: incident.name, level: level))
            } else {
                for component in affected {
                    issues.append(SiteIssue(component: component.name, title: incident.name, level: level))
                }
            }
        }

        if issues.isEmpty {
            for component in summary.components ?? [] where Self.isDegraded(component.status) {
                issues.append(SiteIssue(
                    component: component.name,
                    title: Self.humanize(component.status),
                    level: Self.level(forComponentStatus: component.status)
                ))
            }
        }

        return issues
    }

    private static func isDegraded(_ status: String) -> Bool {
        status != "operational"
    }

    /// Maps a Statuspage `indicator`/`impact` string to a normalized level.
    static func level(forIndicator indicator: String) -> StatusLevel {
        switch indicator.lowercased() {
        case "none":
            return .operational
        case "minor", "maintenance":
            return .minor
        case "major", "critical":
            return .major
        default:
            return .unknown
        }
    }

    /// Maps a Statuspage component `status` to a normalized level.
    static func level(forComponentStatus status: String) -> StatusLevel {
        switch status.lowercased() {
        case "operational":
            return .operational
        case "degraded_performance", "under_maintenance", "partial_outage":
            return .minor
        case "major_outage":
            return .major
        default:
            return .unknown
        }
    }

    /// Turns a component status token like `partial_outage` into `Partial Outage`.
    static func humanize(_ token: String) -> String {
        token
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
