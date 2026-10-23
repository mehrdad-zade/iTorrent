import Foundation
import Observation
import SwiftUI // Array.move(fromOffsets:toOffset:) and remove(atOffsets:)

/// One search site the user has configured. Order in `SourceStore.sources` is priority order.
nonisolated struct SourceConfig: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Classic HTML page at `/search/<query>/<page>/99/0` (most mirrors and proxies).
        case html
        /// apibay-style JSON at `/q.php?q=<query>` (what thepiratebay.org itself uses).
        case api

        var label: String {
            switch self {
            case .html: "Classic search page"
            case .api: "JSON API (apibay)"
            }
        }
    }

    var id = UUID()
    var url: URL
    var kind: Kind

    var host: String { url.host() ?? url.absoluteString }

    func makeSource() -> any TorrentSource {
        switch kind {
        case .html: PirateBayHTMLSource(name: host, baseURL: url)
        case .api: ApiBaySource(name: host, baseURL: apiBaseURL)
        }
    }

    /// thepiratebay.org serves a JavaScript app; its data comes from apibay.org.
    private var apiBaseURL: URL {
        ["thepiratebay.org", "www.thepiratebay.org"].contains(host) ? URL(string: "https://apibay.org")! : url
    }

    /// Turns user input like "tpb.party" or "https://x.org/search/foo" into a site root URL.
    static func normalizedURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func guessKind(for url: URL) -> Kind {
        let host = url.host() ?? ""
        return host.contains("apibay") || ["thepiratebay.org", "www.thepiratebay.org"].contains(host) ? .api : .html
    }
}

@Observable
final class SourceStore {
    static let shared = SourceStore()

    static let defaults = [
        SourceConfig(url: URL(string: "https://thepiratebay0.org")!, kind: .html),
        SourceConfig(url: URL(string: "https://thepiratebay.org")!, kind: .api),
    ]

    private static let key = "searchSources"

    var sources: [SourceConfig] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([SourceConfig].self, from: data) {
            sources = saved
        } else {
            sources = Self.defaults
        }
    }

    /// Search sources in priority order.
    func makeSources() -> [any TorrentSource] { sources.map { $0.makeSource() } }

    enum AddError: LocalizedError {
        case invalidURL, duplicate

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a web address like thepiratebay10.org"
            case .duplicate: "That source is already in the list"
            }
        }
    }

    func add(_ text: String, kind: SourceConfig.Kind) throws {
        guard let url = SourceConfig.normalizedURL(from: text) else { throw AddError.invalidURL }
        guard !sources.contains(where: { $0.url == url && $0.kind == kind }) else { throw AddError.duplicate }
        sources.append(SourceConfig(url: url, kind: kind))
    }

    func move(from offsets: IndexSet, to destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
    }

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
    }

    func resetToDefaults() {
        sources = Self.defaults
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(sources), forKey: Self.key)
    }
}
