import Foundation
import JavaScriptCore

public enum AdapterError: Error, Sendable {
    case contextUnavailable
    case scriptError(String)
    case noAdapterRegistered
    case missingFunction(String)
    case callFailed(String)
}

/// The normalized status an adapter's `parse` produced.
public struct ParsedStatus: Sendable {
    public let level: StatusLevel
    public let detail: String
    public let issues: [SiteIssue]
}

/// Wraps one TypeScript-authored adapter, compiled to JS and run in an isolated
/// JavaScriptCore context. Adapters are **pure parsers**: `endpoint(baseURL)`
/// decides which URL to fetch, `parse(body)` normalizes the response — the host
/// does all networking.
///
/// An `actor` because a `JSContext` must not be used concurrently. Each adapter
/// gets its own context (own VM), so different adapters run in parallel while
/// calls into a single adapter serialize. `id`/`name`/`suggestedSites` are
/// immutable and readable without `await`.
public actor JSAdapter {
    public nonisolated let id: String
    public nonisolated let name: String
    public nonisolated let suggestedSites: [SiteConfig]

    private let context: JSContext
    private let adapter: JSValue
    private let exceptions: ExceptionBox

    final class ExceptionBox: @unchecked Sendable {
        var message: String?
    }

    /// Evaluate `script` (a built adapter bundle that calls `defineAdapter`) and
    /// capture its metadata. Throws if the script errors or registers nothing.
    public init(script: String) throws {
        guard let context = JSContext() else { throw AdapterError.contextUnavailable }
        let exceptions = ExceptionBox()
        context.exceptionHandler = { _, value in
            exceptions.message = value?.toString()
        }

        // Provide `defineAdapter` as a host global so a plain-JavaScript adapter
        // can register itself with no imports and no build step:
        //   defineAdapter({ id, name, endpoint, parse })
        // (The bundled TypeScript SDK sets the same global directly, so built
        // adapters work too.)
        let defineAdapter: @convention(block) (JSValue?) -> JSValue? = { value in
            if let value, let current = JSContext.current() {
                current.setObject(value, forKeyedSubscript: "__STATUSBAR_ADAPTER__" as NSString)
            }
            return value
        }
        context.setObject(defineAdapter, forKeyedSubscript: "defineAdapter" as NSString)

        context.evaluateScript(script)
        if let message = exceptions.message { throw AdapterError.scriptError(message) }

        guard let adapter = context.objectForKeyedSubscript("__STATUSBAR_ADAPTER__"),
            !adapter.isUndefined, !adapter.isNull
        else {
            throw AdapterError.noAdapterRegistered
        }

        let id = adapter.objectForKeyedSubscript("id")?.toString() ?? ""
        self.id = id
        self.name = adapter.objectForKeyedSubscript("name")?.toString() ?? id
        self.suggestedSites = Self.readSuggestedSites(from: adapter, adapterID: id)
        self.context = context
        self.adapter = adapter
        self.exceptions = exceptions
    }

    private static func readSuggestedSites(from adapter: JSValue, adapterID: String) -> [SiteConfig]
    {
        guard let array = adapter.objectForKeyedSubscript("suggestedSites"),
            array.isArray,
            let count = array.objectForKeyedSubscript("length")?.toInt32()
        else {
            return []
        }
        var sites: [SiteConfig] = []
        for i in 0..<Int(count) {
            guard let entry = array.atIndex(i),
                let sid = entry.objectForKeyedSubscript("id")?.toString(),
                let sname = entry.objectForKeyedSubscript("name")?.toString(),
                let surl = entry.objectForKeyedSubscript("url")?.toString(),
                let url = URL(string: surl)
            else { continue }
            sites.append(SiteConfig(id: sid, name: sname, adapterID: adapterID, url: url))
        }
        return sites
    }

    /// Ask the adapter which URL to fetch for a site with the given base URL.
    public func endpoint(baseURL: String) throws -> String {
        exceptions.message = nil
        guard let fn = adapter.objectForKeyedSubscript("endpoint"), fn.isObject else {
            throw AdapterError.missingFunction("endpoint")
        }
        let result = fn.call(withArguments: [baseURL])
        if let message = exceptions.message { throw AdapterError.callFailed(message) }
        guard let string = result?.toString(), !string.isEmpty else {
            throw AdapterError.callFailed("endpoint returned no URL")
        }
        return string
    }

    /// Run the adapter's `parse` on a fetched body and normalize the result.
    public func parse(body: String, baseURL: String) throws -> ParsedStatus {
        exceptions.message = nil
        guard let fn = adapter.objectForKeyedSubscript("parse"), fn.isObject else {
            throw AdapterError.missingFunction("parse")
        }
        let ctxArg: [String: Any] = ["baseURL": baseURL]
        guard let result = fn.call(withArguments: [body, ctxArg]) else {
            throw AdapterError.callFailed("parse returned nothing")
        }
        if let message = exceptions.message { throw AdapterError.callFailed(message) }

        // Marshal via JSON.stringify → Codable, which is robust across JS shapes.
        guard
            let json = context.objectForKeyedSubscript("JSON")?
                .objectForKeyedSubscript("stringify")?
                .call(withArguments: [result])?.toString(),
            let data = json.data(using: .utf8)
        else {
            throw AdapterError.callFailed("could not serialize parse result")
        }
        let raw = try JSONDecoder().decode(RawStatus.self, from: data)
        return raw.normalized()
    }

    private struct RawStatus: Decodable {
        let level: String
        let detail: String
        let issues: [RawIssue]?

        struct RawIssue: Decodable {
            let component: String?
            let title: String
            let level: String?
            let startedAt: String?
        }

        func normalized() -> ParsedStatus {
            let overall = StatusLevel(rawValue: level) ?? .unknown
            let mapped = (issues ?? []).map { issue in
                SiteIssue(
                    component: issue.component,
                    title: issue.title,
                    level: issue.level.flatMap(StatusLevel.init(rawValue:)) ?? overall,
                    startedAt: issue.startedAt.flatMap(Self.parseDate)
                )
            }
            return ParsedStatus(level: overall, detail: detail, issues: mapped)
        }

        /// Parse an ISO 8601 string (with or without fractional seconds).
        static func parseDate(_ string: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }
    }
}
