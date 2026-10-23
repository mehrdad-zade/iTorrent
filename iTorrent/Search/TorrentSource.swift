import Foundation

nonisolated struct SourcePage: Sendable {
    let results: [SearchResult]
    /// Whether requesting `page + 1` can return more results.
    let hasMore: Bool
}

nonisolated protocol TorrentSource: Sendable {
    var name: String { get }
    /// Fetches a 1-based page of results for `query`.
    func fetchPage(query: String, page: Int) async throws -> SourcePage
}

nonisolated enum SourceError: LocalizedError {
    case badStatus(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Server responded with HTTP \(code)"
        case .unreadable: "Could not read the server response"
        }
    }
}

nonisolated enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badStatus(http.statusCode)
        }
        return data
    }

    static func post(_ url: URL, json body: some Encodable, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badStatus(http.statusCode)
        }
        return data
    }

    /// Percent-encodes a single path or query component.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}
