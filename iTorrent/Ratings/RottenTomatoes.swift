import Foundation
import SwiftSoup

/// Title (and year) guessed from a torrent name like "Finch.2021.1080p.WEBRip.x265".
nonisolated struct MediaQuery: Hashable, Sendable {
    let title: String
    let year: Int?
    let isTV: Bool

    /// Words that start the release-info part of a torrent name.
    private static let releaseInfo = #"(?i)\b(S\d{1,2}(E\d{1,3})?|Season\s*\d+|Complete|2160p|1080p|720p|576p|480p|4K|UHD|HDR|WEB[- ]?DL|WEB[- ]?Rip|WEB|BluRay|Blu[- ]Ray|BRRip|BDRip|HDRip|DVDRip|DVDScr|HDTV|HDCAM|CAM|TS|x264|x265|H ?26[45]|HEVC|AAC|DDP?5 1|REMASTERED|EXTENDED|UNRATED|PROPER|REPACK|MULTI|DUAL|IMAX)\b"#
    private static let yearPattern = #"\b(19[2-9]\d|20[0-4]\d)\b"#
    private static let tvPattern = #"(?i)\b(S\d{1,2}(E\d{1,3})?|Season\s*\d+)\b"#

    static func parse(torrentName: String) -> MediaQuery? {
        var name = torrentName.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        // Leading tags such as "[TGx]" or "www.example.org - ".
        name = name.replacingOccurrences(of: #"^\s*(\[[^\]]*\]\s*|www \S+ \S+\s*-\s*)+"#, with: "", options: .regularExpression)

        // A year at the very start is the title ("1917", "2012"), so look for years after it.
        let afterFirstWord = name.firstIndex(of: " ") ?? name.endIndex
        let releaseStart = name.range(of: releaseInfo, options: .regularExpression,
                                      range: afterFirstWord..<name.endIndex)?.lowerBound ?? name.endIndex
        let bracketStart = name.range(of: #"[\[\(\{]"#, options: .regularExpression,
                                      range: afterFirstWord..<name.endIndex)?.lowerBound ?? name.endIndex

        // Prefer a bracketed year ("(2017)"); otherwise the last year before the release info, so a
        // year inside the title ("Blade Runner 2049 2017 1080p") isn't taken as the release year.
        let years = name.ranges(of: try! Regex(yearPattern))
            .filter { $0.lowerBound >= afterFirstWord && $0.lowerBound < releaseStart }
        let yearRange = years.first { $0.lowerBound > name.startIndex && "([{".contains(name[name.index(before: $0.lowerBound)]) }
            ?? years.last
        let cut = min(yearRange?.lowerBound ?? name.endIndex, releaseStart, bracketStart)

        let title = String(name[..<cut])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:+"))
            // Region tags ("The Office US") aren't part of the title on Rotten Tomatoes.
            .replacingOccurrences(of: #"\s+\(?(US|UK|AU|NZ|CA)\)?$"#, with: "", options: .regularExpression)
        guard title.count >= 2 else { return nil }

        let year = yearRange.flatMap { Int(name[$0]) }
        return MediaQuery(title: title, year: year, isTV: name.range(of: tvPattern, options: .regularExpression) != nil)
    }
}

nonisolated struct RTScores: Hashable, Sendable {
    struct Score: Hashable, Sendable, Codable {
        let value: Int
        let isPositive: Bool
        let isCertified: Bool
    }

    let title: String
    let pageURL: URL
    let tomatometer: Score?
    let popcornmeter: Score?
}

/// Looks up Tomatometer and Popcornmeter scores on rottentomatoes.com.
actor RatingsService {
    static let shared = RatingsService()

    private let base = URL(string: "https://www.rottentomatoes.com")!
    private var cache: [MediaQuery: Task<RTScores?, Never>] = [:]

    func scores(for query: MediaQuery) async -> RTScores? {
        if let task = cache[query] { return await task.value }
        let task = Task { try? await self.lookup(query) }
        cache[query] = task
        return await task.value
    }

    private func lookup(_ query: MediaQuery) async throws -> RTScores? {
        var components = URLComponents(url: base.appending(path: "search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "search", value: query.title)]
        let searchHTML = String(decoding: try await HTTP.get(components.url!), as: UTF8.self)
        guard let match = try Self.bestMatch(for: query, inSearchPage: searchHTML) else { return nil }

        let pageHTML = String(decoding: try await HTTP.get(match.url), as: UTF8.self)
        let (critics, audience) = Self.scores(inPage: pageHTML)
        guard critics != nil || audience != nil else { return nil }
        return RTScores(title: match.title, pageURL: match.url, tomatometer: critics, popcornmeter: audience)
    }

    struct Candidate: Equatable {
        let title: String
        let url: URL
        let year: Int?
    }

    static func candidates(inSearchPage html: String) throws -> [Candidate] {
        try SwiftSoup.parse(html).select("search-page-media-row").array().compactMap { row in
            guard let link = try row.select("a[data-qa=info-name]").first(),
                  let url = URL(string: try link.attr("href")) else { return nil }
            let releaseYear = try row.attr("release-year"), startYear = try row.attr("start-year")
            let year = Int(releaseYear) ?? Int(startYear)
            return Candidate(title: try link.text(), url: url, year: year)
        }
    }

    static func bestMatch(for query: MediaQuery, inSearchPage html: String) throws -> Candidate? {
        let wanted = normalize(query.title)
        let kindPrefix = query.isTV ? "/tv/" : "/m/"
        return try candidates(inSearchPage: html)
            .filter { $0.url.path().hasPrefix(kindPrefix) }
            .enumerated()
            .compactMap { rank, candidate -> (Candidate, Int)? in
                let title = normalize(candidate.title)
                var score = 0
                if title == wanted { score += 4 } else if title.contains(wanted) || wanted.contains(title) { score += 1 } else { return nil }
                if let year = query.year, let candidateYear = candidate.year {
                    if year == candidateYear { score += 3 } else if abs(year - candidateYear) == 1 { score += 1 } else if !query.isTV { score -= 3 }
                }
                // Exact title (4), or partial title with a matching year (1 + 3); a wrong year rules a movie out.
                // Ties go to RT's own ordering (most relevant first).
                return score >= 2 ? (candidate, score * 100 - rank) : nil
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Reads `"criticsScore":{…}` (Tomatometer) and `"audienceScore":{…}` (Popcornmeter) from a movie or TV page.
    static func scores(inPage html: String) -> (RTScores.Score?, RTScores.Score?) {
        func score(_ key: String) -> RTScores.Score? {
            guard let object = html.range(of: #""\#(key)":\{[^{}]*\}"#, options: .regularExpression).map({ String(html[$0]) }),
                  let value = capture(#""score":"(\d+)""#, in: object).flatMap(Int.init)
            else { return nil }
            let sentiment = capture(#""sentiment":"(\w+)""#, in: object)
            return RTScores.Score(value: value,
                                  isPositive: sentiment.map { $0 == "POSITIVE" } ?? (value >= 60),
                                  isCertified: object.contains(#""certified":true"#))
        }
        return (score("criticsScore"), score("audienceScore"))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

extension SearchResult {
    /// Only video results get a Rotten Tomatoes lookup.
    nonisolated var mediaQuery: MediaQuery? {
        type.hasPrefix("Video") ? MediaQuery.parse(torrentName: name) : nil
    }
}
