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

/// A minimal inline adapter used across tests (no SDK/build step needed).
private let testAdapterScript = """
    globalThis.__STATUSBAR_ADAPTER__ = {
      id: 'test',
      name: 'Test Adapter',
      endpoint: function (base) { return base.replace(/\\/$/, '') + '/status.json'; },
      parse: function (body, ctx) {
        var d = JSON.parse(body);
        return { level: d.level, detail: d.detail, issues: d.issues || [] };
      },
      suggestedSites: [{ id: 'example', name: 'Example', url: 'https://example.com' }]
    };
    """

// MARK: - JSAdapter runtime

final class JSAdapterTests: XCTestCase {
    func testMetadataAndSuggestedSites() throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        XCTAssertEqual(adapter.id, "test")
        XCTAssertEqual(adapter.name, "Test Adapter")
        XCTAssertEqual(adapter.suggestedSites.count, 1)
        XCTAssertEqual(adapter.suggestedSites.first?.adapterID, "test")
        XCTAssertEqual(adapter.suggestedSites.first?.url.absoluteString, "https://example.com")
    }

    func testEndpoint() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        let endpoint = try await adapter.endpoint(baseURL: "https://x.com/")
        XCTAssertEqual(endpoint, "https://x.com/status.json")
    }

    func testParseMapsLevelAndIssues() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        let body =
            #"{"level":"minor","detail":"Degraded","issues":[{"component":"API","title":"Slow"}]}"#
        let parsed = try await adapter.parse(body: body, baseURL: "https://x.com")
        XCTAssertEqual(parsed.level, .minor)
        XCTAssertEqual(parsed.detail, "Degraded")
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues.first?.summary, "API — Slow")
        XCTAssertEqual(parsed.issues.first?.level, .minor)  // inherits overall
    }

    func testInvalidLevelBecomesUnknown() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        let parsed = try await adapter.parse(
            body: #"{"level":"banana","detail":"?"}"#, baseURL: "x")
        XCTAssertEqual(parsed.level, .unknown)
    }

    func testScriptWithoutAdapterThrows() {
        XCTAssertThrowsError(try JSAdapter(script: "var x = 1;"))
    }

    func testPlainJSViaHostDefineAdapter() throws {
        // No SDK import, no build — relies on the injected host `defineAdapter`.
        let script = """
            defineAdapter({
              id: 'plain', name: 'Plain JS',
              endpoint: function (b) { return b; },
              parse: function (body) { return { level: 'operational', detail: 'ok' }; }
            });
            """
        let adapter = try JSAdapter(script: script)
        XCTAssertEqual(adapter.id, "plain")
        XCTAssertEqual(adapter.name, "Plain JS")
    }

    func testParseThrowOnBadJSON() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        await XCTAssertThrowsErrorAsync(try await adapter.parse(body: "not json", baseURL: "x"))
    }
}

// MARK: - Registry

final class AdapterRegistryTests: XCTestCase {
    func testIndexesAndAggregatesSuggestedSites() throws {
        let a = try JSAdapter(script: testAdapterScript)
        let registry = AdapterRegistry(adapters: [a])
        XCTAssertEqual(registry.adapterIDs, ["test"])
        XCTAssertNotNil(registry.adapter(id: "test"))
        XCTAssertNil(registry.adapter(id: "nope"))
        XCTAssertEqual(registry.suggestedSites.map(\.id), ["example"])
    }

    func testLoadsBareJSFileFromDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("adaptertest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let js = """
            defineAdapter({
              id: 'dropin', name: 'Drop In',
              endpoint: function (b) { return b; },
              parse: function (x) { return { level: 'operational', detail: 'ok' }; },
              suggestedSites: [{ id: 'd', name: 'D', url: 'https://d.com' }]
            });
            """
        try js.write(to: dir.appendingPathComponent("dropin.js"), atomically: true, encoding: .utf8)

        let registry = AdapterRegistry.load(searchPaths: [dir])
        XCTAssertEqual(registry.adapterIDs, ["dropin"])
        XCTAssertEqual(registry.suggestedSites.map(\.id), ["d"])
        XCTAssertEqual(registry.suggestedSites.first?.adapterID, "dropin")
    }
}

// MARK: - Monitor

final class StatusMonitorTests: XCTestCase {
    func testRefreshMapsAdapterResultsAndOrder() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        let registry = AdapterRegistry(adapters: [adapter])
        let good = #"{"level":"major","detail":"Boom","issues":[]}"#
        let fetcher = StubFetcher(routes: [("x.com", Data(good.utf8), 200)])
        let monitor = StatusMonitor(registry: registry, fetcher: fetcher)

        let config = AppConfiguration(sites: [
            SiteConfig(
                id: "s1", name: "One", adapterID: "test", url: URL(string: "https://x.com")!),
            SiteConfig(
                id: "s2", name: "Two", adapterID: "missing", url: URL(string: "https://y.com")!),
            SiteConfig(
                id: "off", name: "Off", adapterID: "test", url: URL(string: "https://x.com")!,
                enabled: false),
        ])

        let results = await monitor.refresh(config: config)
        XCTAssertEqual(results.map(\.siteID), ["s1", "s2"])  // enabled only, in order
        XCTAssertEqual(results[0].level, .major)
        XCTAssertEqual(results[0].detail, "Boom")
        XCTAssertEqual(results[1].level, .unknown)  // no adapter
    }

    func testNon2xxBecomesUnknown() async throws {
        let adapter = try JSAdapter(script: testAdapterScript)
        let registry = AdapterRegistry(adapters: [adapter])
        let fetcher = StubFetcher(routes: [("x.com", Data("oops".utf8), 503)])
        let monitor = StatusMonitor(registry: registry, fetcher: fetcher)
        let config = AppConfiguration(sites: [
            SiteConfig(id: "s1", name: "One", adapterID: "test", url: URL(string: "https://x.com")!)
        ])
        let results = await monitor.refresh(config: config)
        XCTAssertEqual(results[0].level, .unknown)
    }
}

// MARK: - Model

final class SiteConfigMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> SiteConfig {
        try JSONDecoder().decode(SiteConfig.self, from: Data(json.utf8))
    }

    func testLegacyKindMigratesToAdapterID() throws {
        let sp = try decode(
            #"{"id":"gh","name":"GitHub","kind":"statuspage","url":"https://x.com"}"#)
        XCTAssertEqual(sp.adapterID, "statuspage")
        let aws = try decode(#"{"id":"aws","name":"AWS","kind":"awsHealth","url":"https://x.com"}"#)
        XCTAssertEqual(aws.adapterID, "aws")
    }

    func testAdapterIDFieldWins() throws {
        let c = try decode(
            #"{"id":"x","name":"X","adapterID":"custom","url":"https://x.com","enabled":false}"#)
        XCTAssertEqual(c.adapterID, "custom")
        XCTAssertFalse(c.enabled)
    }

    func testRoundTripEncodesAdapterID() throws {
        let original = SiteConfig(
            id: "x", name: "X", adapterID: "statuspage", url: URL(string: "https://x.com")!)
        let data = try JSONEncoder().encode(original)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"adapterID\""))
        XCTAssertEqual(try JSONDecoder().decode(SiteConfig.self, from: data), original)
    }
}

final class IssueCollapseTests: XCTestCase {
    func testSameTitleAcrossComponentsCollapsesToOne() {
        let issues = (1...16).map {
            SiteIssue(
                component: "region-\($0)", title: "Project status change failures", level: .minor)
        }
        let collapsed = issues.collapsed()
        XCTAssertEqual(collapsed.count, 1)
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
        XCTAssertEqual(collapsed.first?.level, .major)
        XCTAssertNil(collapsed.first?.component)
        XCTAssertEqual(collapsed.last?.component, "B")
    }
}

final class RelativeAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testBuckets() {
        XCTAssertEqual(relativeAge(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(relativeAge(now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(relativeAge(now.addingTimeInterval(-2 * 3600), now: now), "2h ago")
        XCTAssertEqual(relativeAge(now.addingTimeInterval(-3 * 86400), now: now), "3d ago")
        XCTAssertEqual(relativeAge(now.addingTimeInterval(-14 * 86400), now: now), "2w ago")
    }

    func testFutureClampsToJustNow() {
        XCTAssertEqual(relativeAge(now.addingTimeInterval(120), now: now), "just now")
    }
}

final class IssueStartedAtTests: XCTestCase {
    func testAdapterParsesStartedAt() async throws {
        let script = """
            globalThis.__STATUSBAR_ADAPTER__ = {
              id: 't', name: 'T', endpoint: function(b){return b;},
              parse: function(body){ return { level: 'major', detail: 'x',
                issues: [{ title: 'boom', startedAt: '2026-07-09T04:34:24.849Z' }] }; }
            };
            """
        let adapter = try JSAdapter(script: script)
        let parsed = try await adapter.parse(body: "{}", baseURL: "x")
        XCTAssertNotNil(parsed.issues.first?.startedAt)
    }

    func testCollapseKeepsEarliestStart() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 500)
        let issues = [
            SiteIssue(component: "A", title: "Same", level: .minor, startedAt: late),
            SiteIssue(component: "B", title: "Same", level: .minor, startedAt: early),
        ]
        XCTAssertEqual(issues.collapsed().first?.startedAt, early)
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

final class IssueStalenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private let threshold: TimeInterval = 72 * 3600  // 3 days

    private func issue(_ level: StatusLevel, ageHours: Double?) -> SiteIssue {
        let started = ageHours.map { now.addingTimeInterval(-$0 * 3600) }
        return SiteIssue(component: nil, title: "t", level: level, startedAt: started)
    }

    func testMinorGoesStalePastThreshold() {
        XCTAssertTrue(issue(.minor, ageHours: 24 * 21).isStale(threshold: threshold, now: now))
    }

    func testFreshMinorIsNotStale() {
        XCTAssertFalse(issue(.minor, ageHours: 12).isStale(threshold: threshold, now: now))
    }

    func testMajorIsNeverStale() {
        // A long-running major outage still matters, however old.
        XCTAssertFalse(issue(.major, ageHours: 24 * 90).isStale(threshold: threshold, now: now))
    }

    func testNoTimestampIsNeverStale() {
        // A degraded-component fallback with no time reported is a present condition.
        XCTAssertFalse(issue(.minor, ageHours: nil).isStale(threshold: threshold, now: now))
    }

    func testLastUpdatePreemptsStart() {
        // Old start, but a recent update means it's still active → not stale.
        let old = now.addingTimeInterval(-24 * 21 * 3600)
        let recent = now.addingTimeInterval(-3600)
        let i = SiteIssue(component: nil, title: "t", level: .minor, startedAt: old, updatedAt: recent)
        XCTAssertFalse(i.isStale(threshold: threshold, now: now))
    }

    func testCollapseKeepsLatestUpdate() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 900)
        let issues = [
            SiteIssue(component: "A", title: "Same", level: .minor, startedAt: old, updatedAt: old),
            SiteIssue(component: "B", title: "Same", level: .minor, startedAt: old, updatedAt: newer),
        ]
        XCTAssertEqual(issues.collapsed().first?.updatedAt, newer)
    }

    private func siteWith(_ issues: [SiteIssue], level: StatusLevel) -> SiteStatus {
        SiteStatus(siteID: "x", name: "X", level: level, detail: "", issues: issues, checkedAt: now)
    }

    func testEffectiveLevelDropsWhenAllIssuesStale() {
        let site = siteWith([issue(.minor, ageHours: 24 * 21)], level: .minor)
        XCTAssertEqual(site.effectiveLevel(threshold: threshold, now: now), .operational)
    }

    func testEffectiveLevelKeepsWorstFreshIssue() {
        let site = siteWith(
            [issue(.minor, ageHours: 24 * 21), issue(.major, ageHours: 1)], level: .major)
        XCTAssertEqual(site.effectiveLevel(threshold: threshold, now: now), .major)
    }

    func testEffectiveLevelKeepsReportedWhenNoIssues() {
        // No attributable issue → never mask an error/unknown state.
        let site = siteWith([], level: .unknown)
        XCTAssertEqual(site.effectiveLevel(threshold: threshold, now: now), .unknown)
    }

    func testPartitionSplitsFreshFromStale() {
        let site = siteWith(
            [issue(.minor, ageHours: 1), issue(.minor, ageHours: 24 * 21)], level: .minor)
        let (fresh, stale) = site.partitionedIssues(threshold: threshold, now: now)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(stale.count, 1)
    }

    func testOverallLevelIgnoresStaleLowImpact() {
        let staleSite = siteWith([issue(.minor, ageHours: 24 * 21)], level: .minor)
        let goodSite = siteWith([], level: .operational)
        XCTAssertEqual([staleSite, goodSite].overallLevel(threshold: threshold, now: now), .operational)
    }
}

final class ConfigurationDecodeTests: XCTestCase {
    func testLegacyConfigWithoutStaleKeysGetsDefaults() throws {
        let json = #"{"refreshIntervalSeconds":60,"sites":[]}"#
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(config.demoteStaleIssues)
        XCTAssertEqual(config.staleIssueThresholdHours, 72)
    }

    func testRoundTripPreservesStaleSettings() throws {
        let original = AppConfiguration(
            sites: [], demoteStaleIssues: false, staleIssueThresholdHours: 12)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Helpers

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
