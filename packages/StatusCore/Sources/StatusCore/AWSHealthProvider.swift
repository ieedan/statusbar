import Foundation

/// Reads status from the AWS Health "current events" feed.
///
/// AWS does not run a Statuspage. Instead it publishes a JSON array of
/// currently-active events at `https://health.aws.amazon.com/public/currentevents`.
/// Notably the feed is served as UTF-16 (with a byte-order mark), so the body is
/// transcoded to UTF-8 before decoding. Each event carries a numeric `status`:
///   1 = informational, 2 = degraded performance, 3 = service disruption.
public struct AWSHealthProvider: StatusProvider {
    public let kind: ProviderKind = .awsHealth
    private let fetcher: HTTPFetching

    /// Public dashboard URL to open when the user clicks the AWS row.
    public static let dashboardURL = URL(string: "https://health.aws.amazon.com/health/status")!

    public init(fetcher: HTTPFetching = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    private struct Event: Decodable {
        let status: String
        let summary: String?
        let service_name: String?
    }

    public func fetchStatus(for site: SiteConfig) async throws -> SiteStatus {
        let (raw, code) = try await fetcher.data(from: site.url)
        guard (200..<300).contains(code) else { throw ProviderError.badResponse(status: code) }
        let data = Self.normalizedUTF8(raw)
        guard !data.isEmpty else { throw ProviderError.emptyBody }

        let events: [Event]
        do {
            events = try JSONDecoder().decode([Event].self, from: data)
        } catch {
            throw ProviderError.decoding("\(error)")
        }

        // Turn every active event into an issue, and reduce to a worst level.
        var worst: StatusLevel = .operational
        var issues: [SiteIssue] = []
        for event in events {
            let level = Self.level(forStatusCode: event.status)
            if level.severity > worst.severity { worst = level }
            issues.append(SiteIssue(
                component: event.service_name,
                title: event.summary ?? "Active event",
                level: level
            ))
        }

        let detail: String
        switch worst {
        case .major: detail = "Major Service Outage"
        case .minor: detail = "Service Degradation"
        default:     detail = "All Systems Operational"
        }

        return SiteStatus(
            siteID: site.id,
            name: site.name,
            level: worst,
            detail: detail,
            issues: issues.collapsed(),
            checkedAt: Date(),
            pageURL: Self.dashboardURL
        )
    }

    /// Maps an AWS numeric status code (as a string) to a normalized level.
    static func level(forStatusCode code: String) -> StatusLevel {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "0":
            return .operational
        case "1", "2":
            return .minor
        case "3":
            return .major
        default:
            return .minor
        }
    }

    /// The feed is UTF-16LE with a BOM. Transcode to UTF-8 so `JSONDecoder`
    /// (which expects UTF-8) can read it. Falls back to the raw bytes if the
    /// data is already UTF-8.
    static func normalizedUTF8(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let looksUTF16 = (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)
        if looksUTF16, let string = String(data: data, encoding: .utf16) {
            return Data(string.utf8)
        }
        return data
    }
}
