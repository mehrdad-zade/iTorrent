import Foundation
import SwiftSoup

/// Scrapes the classic HTML search page: `<base>/search/<query>/<page>/99/0`.
nonisolated struct PirateBayHTMLSource: TorrentSource {
    var name = "thepiratebay0.org"
    var baseURL = URL(string: "https://thepiratebay0.org")!

    func fetchPage(query: String, page: Int) async throws -> SourcePage {
        guard let url = searchURL(query: query, page: page) else { throw SourceError.unreadable }
        let data = try await HTTP.get(url)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SourceError.unreadable
        }
        return try parse(html)
    }

    /// Built from a string because `URL.appending(path:)` percent-encodes again, turning
    /// "the%20matrix" into "the%2520matrix", which the site treats as no query at all.
    func searchURL(query: String, page: Int) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/search/\(HTTP.encode(query))/\(page)/99/0")
    }

    func parse(_ html: String) throws -> SourcePage {
        let doc = try SwiftSoup.parse(html)
        var results: [SearchResult] = []

        for row in try doc.select("table#searchResult tr") {
            guard let link = try row.select("a.detLink").first(),
                  let magnet = try row.select("a[href^=magnet:]").first().map({ try $0.attr("href") }),
                  let magnetURL = URL(string: magnet),
                  let hash = InfoHash.from(magnet: magnet)
            else { continue }

            let type = try row.select("td.vertTh a").array().map { try $0.text() }.joined(separator: " > ")
            let desc = try row.select("font.detDesc").first()?.text()
                .replacingOccurrences(of: "\u{00A0}", with: " ") ?? ""

            results.append(SearchResult(
                infoHash: hash,
                name: try link.text(),
                type: type.isEmpty ? "Unknown" : type,
                size: Self.capture(#"Size ([^,]+)"#, in: desc) ?? "?",
                uploader: Self.capture(#"ULed by\s+(.+)$"#, in: desc) ?? "Anonymous",
                magnet: magnetURL,
                sourceName: name
            ))
        }

        let hasNext = try !doc.select("img[alt=Next]").isEmpty()
        return SourcePage(results: results, hasMore: hasNext && !results.isEmpty)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return text[range].trimmingCharacters(in: .whitespaces)
    }
}
