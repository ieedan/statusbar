import Foundation

/// Minimal abstraction over the network so the monitor can be unit-tested with
/// canned responses instead of hitting live status pages. Adapters never touch
/// this — the host performs every request and hands the body to the adapter.
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

/// Decodes a response body to a `String`, transparently handling the UTF-16
/// (BOM-prefixed) encoding that some feeds — notably AWS Health — serve, so
/// adapters always receive clean UTF-8 text to `JSON.parse`.
public func decodeResponseBody(_ data: Data) -> String {
    if data.count >= 2 {
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF),
           let string = String(data: data, encoding: .utf16) {
            return string
        }
    }
    return String(data: data, encoding: .utf8) ?? ""
}
