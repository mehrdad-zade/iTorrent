import Foundation

/// JSON backend behind thepiratebay.org. Returns up to 100 results in one response, with no paging.
nonisolated struct ApiBaySource: TorrentSource {
    var name = "thepiratebay.org"
    var baseURL = URL(string: "https://apibay.org")!

    private struct Item: Decodable {
        let id: String
        let name: String
        let info_hash: String
        let size: String
        let username: String
        let category: String
    }

    func fetchPage(query: String, page: Int) async throws -> SourcePage {
        guard page == 1 else { return SourcePage(results: [], hasMore: false) }
        var components = URLComponents(url: baseURL.appending(path: "q.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cat", value: "0")]
        return try parse(try await HTTP.get(components.url!))
    }

    func parse(_ data: Data) throws -> SourcePage {
        let items = try JSONDecoder().decode([Item].self, from: data)
        let results = items
            .filter { $0.id != "0" } // apibay's "No results returned" sentinel
            .compactMap { item -> SearchResult? in
                let hash = item.info_hash.uppercased()
                guard let magnet = Self.magnet(hash: hash, name: item.name) else { return nil }
                return SearchResult(
                    infoHash: hash,
                    name: item.name,
                    type: Self.categoryName(item.category),
                    size: ByteCountFormatter.string(fromByteCount: Int64(item.size) ?? 0, countStyle: .binary),
                    uploader: item.username,
                    magnet: magnet,
                    sourceName: name
                )
            }
        return SourcePage(results: results, hasMore: false)
    }

    static let trackers = [
        "udp://tracker.opentrackr.org:1337",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://tracker.bittor.pw:1337/announce",
        "udp://public.popcorn-tracker.org:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://exodus.desync.com:6969",
        "udp://open.demonii.com:1337/announce",
    ]

    static func magnet(hash: String, name: String) -> URL? {
        let tr = trackers.map { "&tr=\(HTTP.encode($0))" }.joined()
        return URL(string: "magnet:?xt=urn:btih:\(hash)&dn=\(HTTP.encode(name))\(tr)")
    }

    private static let mainCategories = [1: "Audio", 2: "Video", 3: "Applications", 4: "Games", 5: "Porn", 6: "Other"]
    private static let subCategories = [
        101: "Music", 102: "Audio books", 103: "Sound clips", 104: "FLAC", 199: "Other",
        201: "Movies", 202: "Movies DVDR", 203: "Music videos", 204: "Movie clips", 205: "TV shows",
        206: "Handheld", 207: "HD - Movies", 208: "HD - TV shows", 209: "3D", 210: "CAM/TS",
        211: "UHD/4k - Movies", 212: "UHD/4k - TV shows", 299: "Other",
        301: "Windows", 302: "Mac", 303: "UNIX", 304: "Handheld", 305: "IOS (iPad/iPhone)", 306: "Android", 399: "Other OS",
        401: "PC", 402: "Mac", 403: "PSx", 404: "XBOX360", 405: "Wii", 406: "Handheld", 407: "IOS (iPad/iPhone)",
        408: "Android", 499: "Other",
        601: "E-books", 602: "Comics", 603: "Pictures", 604: "Covers", 605: "Physibles", 699: "Other",
    ]

    /// Formats a category code like "207" as "Video > HD - Movies", matching the HTML source.
    static func categoryName(_ code: String) -> String {
        guard let value = Int(code), let main = mainCategories[value / 100] else { return "Unknown" }
        guard let sub = subCategories[value] else { return main }
        return "\(main) > \(sub)"
    }
}
