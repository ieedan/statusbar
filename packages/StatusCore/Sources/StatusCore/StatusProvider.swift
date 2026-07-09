import Foundation

/// Fetches and normalizes the status for a single configured site.
public protocol StatusProvider: Sendable {
    /// The provider kind this implementation handles.
    var kind: ProviderKind { get }
    /// Fetch the current status for `site`. Throws on network/decoding failure;
    /// callers are expected to translate a throw into a `.unknown` result.
    func fetchStatus(for site: SiteConfig) async throws -> SiteStatus
}

/// Errors surfaced by providers.
public enum ProviderError: Error, Sendable {
    case badResponse(status: Int)
    case emptyBody
    case decoding(String)
}

/// Minimal abstraction over the network so providers can be unit-tested with
/// canned responses instead of hitting the live status pages.
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> (Data, Int)
}

/// Live implementation backed by `URLSession`.
public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        self.timeout = timeout
    }

    public func data(from url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("status-bar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }
}
