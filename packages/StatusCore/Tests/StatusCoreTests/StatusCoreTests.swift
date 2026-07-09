import XCTest
@testable import StatusCore

/// A canned HTTP fetcher returning a fixed body keyed by URL substring.
struct StubFetcher: HTTPFetching {
    let routes: [(match: String, data: Data, code: Int)]

    func data(from url: URL) async throws -> (Data, Int) {
        for route in routes where url.absoluteString.contains(route.match) {
            return (route.data, route.code)
        }
        return (Data(), 404)
    }
}

final class StatuspageProviderTests: XCTestCase {
    func testIndicatorMapping() {
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "none"), .operational)
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "minor"), .minor)
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "maintenance"), .minor)
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "major"), .major)
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "critical"), .major)
        XCTAssertEqual(StatuspageProvider.level(forIndicator: "banana"), .unknown)
    }

    func testHumanizeComponentStatus() {
        XCTAssertEqual(StatuspageProvider.humanize("partial_outage"), "Partial Outage")
        XCTAssertEqual(StatuspageProvider.humanize("degraded_performance"), "Degraded Performance")
    }

    func testFetchParsesResponseAndIncidents() async throws {
        let body = """
        {"status":{"indicator":"minor","description":"Minor Service Outage"},
         "incidents":[{"name":"Delays starting Actions runs","impact":"major",
                       "status":"investigating","components":[{"name":"Actions","status":"partial_outage"}]}]}
        """
        let fetcher = StubFetcher(routes: [("githubstatus", Data(body.utf8), 200)])
        let provider = StatuspageProvider(fetcher: fetcher)
        let site = SiteConfig(id: "github", name: "GitHub", kind: .statuspage,
                              url: URL(string: "https://www.githubstatus.com")!)

        let status = try await provider.fetchStatus(for: site)
        XCTAssertEqual(status.level, .minor)
        XCTAssertEqual(status.detail, "Minor Service Outage")
        XCTAssertEqual(status.issues.count, 1)
        XCTAssertEqual(status.issues.first?.summary, "Actions — Delays starting Actions runs")
        XCTAssertEqual(status.issues.first?.level, .major)
    }

    func testResolvedIncidentsAreIgnored() async throws {
        let body = """
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "incidents":[{"name":"Old thing","impact":"major","status":"resolved","components":[]}]}
        """
        let fetcher = StubFetcher(routes: [("statuspage", Data(body.utf8), 200)])
        let provider = StatuspageProvider(fetcher: fetcher)
        let site = SiteConfig(id: "x", name: "X", kind: .statuspage,
                              url: URL(string: "https://x.statuspage.io")!)
        let status = try await provider.fetchStatus(for: site)
        XCTAssertTrue(status.issues.isEmpty)
    }

    func testDegradedComponentsFallbackWhenNoIncidents() async throws {
        let body = """
        {"status":{"indicator":"minor","description":"Partial Degradation"},
         "incidents":[],
         "components":[{"name":"API","status":"partial_outage"},
                       {"name":"Web","status":"operational"}]}
        """
        let fetcher = StubFetcher(routes: [("statuspage", Data(body.utf8), 200)])
        let provider = StatuspageProvider(fetcher: fetcher)
        let site = SiteConfig(id: "x", name: "X", kind: .statuspage,
                              url: URL(string: "https://x.statuspage.io")!)
        let status = try await provider.fetchStatus(for: site)
        XCTAssertEqual(status.issues.count, 1)
        XCTAssertEqual(status.issues.first?.summary, "API — Partial Outage")
    }

    func testNon2xxThrows() async {
        let fetcher = StubFetcher(routes: [("githubstatus", Data("oops".utf8), 503)])
        let provider = StatuspageProvider(fetcher: fetcher)
        let site = SiteConfig(id: "github", name: "GitHub", kind: .statuspage,
                              url: URL(string: "https://www.githubstatus.com")!)
        await XCTAssertThrowsErrorAsync(try await provider.fetchStatus(for: site))
    }
}

final class AWSHealthProviderTests: XCTestCase {
    func testStatusCodeMapping() {
        XCTAssertEqual(AWSHealthProvider.level(forStatusCode: "0"), .operational)
        XCTAssertEqual(AWSHealthProvider.level(forStatusCode: "1"), .minor)
        XCTAssertEqual(AWSHealthProvider.level(forStatusCode: "2"), .minor)
        XCTAssertEqual(AWSHealthProvider.level(forStatusCode: "3"), .major)
    }

    func testUTF16Normalization() {
        let json = #"[{"status":"3","summary":"Increased Error Rates"}]"#
        // Encode as UTF-16 with BOM, as AWS serves it.
        let utf16 = json.data(using: .utf16)!
        let normalized = AWSHealthProvider.normalizedUTF8(utf16)
        let decoded = String(data: normalized, encoding: .utf8)
        XCTAssertEqual(decoded, json)
    }

    func testFetchPicksWorstEvent() async throws {
        let json = #"[{"status":"1","summary":"Info"},{"status":"3","summary":"Big Outage"}]"#
        let fetcher = StubFetcher(routes: [("currentevents", json.data(using: .utf16)!, 200)])
        let provider = AWSHealthProvider(fetcher: fetcher)
        let site = SiteConfig(id: "aws", name: "AWS", kind: .awsHealth,
                              url: URL(string: "https://health.aws.amazon.com/public/currentevents")!)

        let status = try await provider.fetchStatus(for: site)
        XCTAssertEqual(status.level, .major)
        XCTAssertEqual(status.issues.count, 2)
        XCTAssertTrue(status.issues.contains { $0.title == "Big Outage" && $0.level == .major })
    }

    func testEmptyFeedIsOperational() async throws {
        let fetcher = StubFetcher(routes: [("currentevents", "[]".data(using: .utf16)!, 200)])
        let provider = AWSHealthProvider(fetcher: fetcher)
        let site = SiteConfig(id: "aws", name: "AWS", kind: .awsHealth,
                              url: URL(string: "https://health.aws.amazon.com/public/currentevents")!)

        let status = try await provider.fetchStatus(for: site)
        XCTAssertEqual(status.level, .operational)
    }
}

final class IssueCollapseTests: XCTestCase {
    func testSameTitleAcrossComponentsCollapsesToOne() {
        let issues = (1...16).map {
            SiteIssue(component: "region-\($0)", title: "Project status change failures", level: .minor)
        }
        let collapsed = issues.collapsed()
        XCTAssertEqual(collapsed.count, 1)
        // Multi-component group drops the component in favor of the title alone.
        XCTAssertNil(collapsed.first?.component)
        XCTAssertEqual(collapsed.first?.title, "Project status change failures")
    }

    func testDistinctTitlesPreservedInOrderWithWorstLevel() {
        let issues = [
            SiteIssue(component: "A", title: "One", level: .minor),
            SiteIssue(component: "B", title: "Two", level: .minor),
            SiteIssue(component: "C", title: "One", level: .major),
        ]
        let collapsed = issues.collapsed()
        XCTAssertEqual(collapsed.map(\.title), ["One", "Two"])
        XCTAssertEqual(collapsed.first?.level, .major) // worst wins
        XCTAssertNil(collapsed.first?.component)       // "One" spanned A + C
        XCTAssertEqual(collapsed.last?.component, "B")  // "Two" single component kept
    }
}

final class AggregationTests: XCTestCase {
    private func status(_ level: StatusLevel) -> SiteStatus {
        SiteStatus(siteID: "x", name: "X", level: level, detail: "", checkedAt: Date())
    }

    func testOverallLevelPicksWorst() {
        XCTAssertEqual([status(.operational), status(.minor), status(.major)].overallLevel, .major)
        XCTAssertEqual([status(.operational), status(.minor)].overallLevel, .minor)
        XCTAssertEqual([status(.operational), status(.unknown)].overallLevel, .operational)
        XCTAssertEqual([status(.unknown)].overallLevel, .unknown)
        XCTAssertEqual([SiteStatus]().overallLevel, .unknown)
    }
}

final class StatusMonitorTests: XCTestCase {
    func testRefreshReturnsRowPerEnabledSiteInOrder() async {
        let gh = #"{"status":{"indicator":"none","description":"OK"}}"#
        let fetcher = StubFetcher(routes: [
            ("githubstatus", Data(gh.utf8), 200),
            ("currentevents", "[]".data(using: .utf16)!, 200),
            // vercel-status intentionally unrouted -> 404 -> .unknown
        ])
        let monitor = StatusMonitor(fetcher: fetcher)
        let config = AppConfiguration(sites: [
            SiteConfig(id: "vercel", name: "Vercel", kind: .statuspage,
                       url: URL(string: "https://www.vercel-status.com")!),
            SiteConfig(id: "github", name: "GitHub", kind: .statuspage,
                       url: URL(string: "https://www.githubstatus.com")!),
            SiteConfig(id: "aws", name: "AWS", kind: .awsHealth,
                       url: URL(string: "https://health.aws.amazon.com/public/currentevents")!),
            SiteConfig(id: "off", name: "Off", kind: .statuspage,
                       url: URL(string: "https://example.com")!, enabled: false),
        ])

        let results = await monitor.refresh(config: config)
        XCTAssertEqual(results.map(\.siteID), ["vercel", "github", "aws"])
        XCTAssertEqual(results[0].level, .unknown)     // unrouted
        XCTAssertEqual(results[1].level, .operational) // github OK
        XCTAssertEqual(results[2].level, .operational) // aws empty feed
    }
}

// MARK: - Async assertion helper

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error but none was thrown", file: file, line: line)
    } catch {
        // expected
    }
}
