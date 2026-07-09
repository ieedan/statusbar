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

/// A configured site to monitor.
public struct SiteConfig: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier, e.g. `"github"`. Used to correlate results across refreshes.
    public var id: String
    /// Human-facing display name, e.g. `"GitHub"`.
    public var name: String
    /// Which adapter reads this site's status, e.g. `"statuspage"` or `"aws"`.
    public var adapterID: String
    /// The site's base URL, passed to the adapter's `endpoint(baseURL)`.
    public var url: URL
    /// Whether this site is actively monitored.
    public var enabled: Bool

    public init(id: String, name: String, adapterID: String, url: URL, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.adapterID = adapterID
        self.url = url
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, adapterID, url, enabled, kind
    }

    /// Custom decode so configs written before adapters existed still load:
    /// the legacy `kind` field ("statuspage"/"awsHealth") maps to an adapter id.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(URL.self, forKey: .url)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let adapter = try c.decodeIfPresent(String.self, forKey: .adapterID) {
            adapterID = adapter
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .kind) {
            adapterID = (legacy == "awsHealth") ? "aws" : legacy
        } else {
            adapterID = "statuspage"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(adapterID, forKey: .adapterID)
        try c.encode(url, forKey: .url)
        try c.encode(enabled, forKey: .enabled)
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
    /// When the issue began, if the source reports it.
    public let startedAt: Date?
    /// When the source last updated this issue, if reported. Distinguishes an
    /// actively-worked incident from one that has gone quiet.
    public let updatedAt: Date?

    public init(
        component: String?, title: String, level: StatusLevel,
        startedAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.component = component
        self.title = title
        self.level = level
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// One-line rendering, e.g. `"Actions — Delays starting Actions runs"`.
    public var summary: String {
        if let component, !component.isEmpty {
            return "\(component) — \(title)"
        }
        return title
    }

    /// The most recent time we have evidence this issue was active: the last
    /// source update if available, otherwise its start. `nil` when the source
    /// reports neither (e.g. a degraded-component fallback), which we treat as a
    /// present condition — never stale.
    public var lastActivity: Date? { updatedAt ?? startedAt }

    /// Whether this issue is stale: low-impact *and* quiet for longer than
    /// `threshold`. A long-running lingering `minor` incident that hasn't been
    /// touched in days is exactly this. Major outages are never stale — a long
    /// major incident still matters — and issues with no timestamp are never
    /// stale, since we can't judge their age.
    public func isStale(threshold: TimeInterval, now: Date) -> Bool {
        guard level != .major else { return false }
        guard let last = lastActivity else { return false }
        return now.timeIntervalSince(last) > threshold
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

    /// The worst *effective* level across all results — like `overallLevel`, but
    /// stale low-impact issues no longer count, so the menubar icon can settle
    /// back to green while a lingering minor incident is merely demoted, not gone.
    func overallLevel(threshold: TimeInterval, now: Date) -> StatusLevel {
        self.map { $0.effectiveLevel(threshold: threshold, now: now) }
            .max(by: { $0.severity < $1.severity }) ?? .unknown
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
            let earliest = group.compactMap(\.startedAt).min()
            let latestUpdate = group.compactMap(\.updatedAt).max()
            return SiteIssue(
                component: component, title: title, level: worst,
                startedAt: earliest, updatedAt: latestUpdate)
        }
    }
}

public extension SiteStatus {
    /// Splits this site's issues into the ones worth surfacing now (`fresh`) and
    /// the lingering low-impact ones that have gone quiet (`stale`). Order within
    /// each group is preserved.
    func partitionedIssues(threshold: TimeInterval, now: Date) -> (fresh: [SiteIssue], stale: [SiteIssue]) {
        var fresh: [SiteIssue] = []
        var stale: [SiteIssue] = []
        for issue in issues {
            if issue.isStale(threshold: threshold, now: now) {
                stale.append(issue)
            } else {
                fresh.append(issue)
            }
        }
        return (fresh, stale)
    }

    /// The level this site should display once stale low-impact issues are set
    /// aside. When every issue is stale, the site reads operational — so a
    /// three-week-old minor incident no longer keeps the row (and the menubar
    /// icon) lit. A site with no attributable issues keeps its reported level,
    /// so error/unknown states are never masked.
    func effectiveLevel(threshold: TimeInterval, now: Date) -> StatusLevel {
        guard !issues.isEmpty else { return level }
        let fresh = issues.filter { !$0.isStale(threshold: threshold, now: now) }
        guard let worst = fresh.map(\.level).max(by: { $0.severity < $1.severity }) else {
            return .operational
        }
        return worst
    }
}
