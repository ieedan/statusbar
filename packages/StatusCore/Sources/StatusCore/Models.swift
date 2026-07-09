import Foundation

/// Normalized status level for a monitored site.
///
/// The menubar maps these to colors: `.major` → red, `.minor` → orange,
/// `.operational` and `.unknown` → gray (good / no signal).
public enum StatusLevel: String, Codable, Sendable, CaseIterable {
    /// No signal yet (never checked, network error, or unparseable response).
    case unknown
    /// All systems operational.
    case operational
    /// A partial or minor incident is in progress.
    case minor
    /// A major or critical outage is in progress.
    case major

    /// Ordinal severity used to pick the "worst" status when aggregating.
    /// A real incident always outranks `.unknown`, which outranks `.operational`.
    public var severity: Int {
        switch self {
        case .unknown: return 0
        case .operational: return 1
        case .minor: return 2
        case .major: return 3
        }
    }
}

/// The kind of upstream status source backing a site.
public enum ProviderKind: String, Codable, Sendable {
    /// An Atlassian Statuspage instance exposing `/api/v2/status.json`.
    case statuspage
    /// The AWS Health "current events" JSON feed.
    case awsHealth
}

/// A configured site to monitor.
public struct SiteConfig: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier, e.g. `"github"`. Used to correlate results across refreshes.
    public var id: String
    /// Human-facing display name, e.g. `"GitHub"`.
    public var name: String
    /// Which provider knows how to read this site's status.
    public var kind: ProviderKind
    /// For `.statuspage`: the page base URL (e.g. `https://www.githubstatus.com`).
    /// For `.awsHealth`: the current-events feed URL.
    public var url: URL
    /// Whether this site is actively monitored.
    public var enabled: Bool

    public init(id: String, name: String, kind: ProviderKind, url: URL, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.enabled = enabled
    }
}

/// A single active issue affecting a site — a Statuspage incident or an AWS
/// health event. These render as the indented detail lines under a site.
public struct SiteIssue: Sendable, Equatable, Identifiable {
    public var id: String { "\(component ?? "")|\(title)" }
    /// The affected component/service, e.g. `"Actions"` or `"Claude"`. May be nil.
    public let component: String?
    /// A short description of the issue, e.g. `"Delays starting Actions runs"`.
    public let title: String
    /// Severity of this specific issue.
    public let level: StatusLevel

    public init(component: String?, title: String, level: StatusLevel) {
        self.component = component
        self.title = title
        self.level = level
    }

    /// One-line rendering, e.g. `"Actions — Delays starting Actions runs"`.
    public var summary: String {
        if let component, !component.isEmpty {
            return "\(component) — \(title)"
        }
        return title
    }
}

/// The result of checking a single site.
public struct SiteStatus: Sendable, Identifiable, Equatable {
    public var id: String { siteID }
    /// Matches the originating `SiteConfig.id`.
    public let siteID: String
    public let name: String
    public let level: StatusLevel
    /// Human-readable description, e.g. `"All Systems Operational"`.
    public let detail: String
    /// The individual active issues affecting this site, if any.
    public let issues: [SiteIssue]
    /// When this result was produced.
    public let checkedAt: Date
    /// A URL the user can open to see the full status page, if available.
    public let pageURL: URL?

    public init(
        siteID: String,
        name: String,
        level: StatusLevel,
        detail: String,
        issues: [SiteIssue] = [],
        checkedAt: Date,
        pageURL: URL? = nil
    ) {
        self.siteID = siteID
        self.name = name
        self.level = level
        self.detail = detail
        self.issues = issues
        self.checkedAt = checkedAt
        self.pageURL = pageURL
    }
}

public extension Array where Element == SiteStatus {
    /// The worst status level across all results — the level the menubar icon reflects.
    /// Returns `.unknown` for an empty set.
    var overallLevel: StatusLevel {
        self.map(\.level).max(by: { $0.severity < $1.severity }) ?? .unknown
    }
}

public extension Array where Element == SiteIssue {
    /// Collapses issues that share a title into one. A single incident often
    /// spans many components/regions (e.g. the same failure across 16 Supabase
    /// regions), which would otherwise flood the menu. Keeps first-seen order
    /// and the worst level; when a title spans multiple components the component
    /// is dropped in favor of the title alone.
    func collapsed() -> [SiteIssue] {
        var order: [String] = []
        var groups: [String: [SiteIssue]] = [:]
        for issue in self {
            if groups[issue.title] == nil { order.append(issue.title) }
            groups[issue.title, default: []].append(issue)
        }
        return order.map { title in
            let group = groups[title]!
            let worst = group.max { $0.level.severity < $1.level.severity }?.level ?? .unknown
            let component = group.count == 1 ? group[0].component : nil
            return SiteIssue(component: component, title: title, level: worst)
        }
    }
}
