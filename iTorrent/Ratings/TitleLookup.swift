import Foundation

/// The movie or show a search is about: its IMDb entry and Rotten Tomatoes scores.
nonisolated struct TitleInfo: Hashable, Sendable {
    let title: String
    let year: Int?
    let isTV: Bool
    let imdbID: String?
    let posterURL: URL?
    let scores: RTScores?

    /// Opens the IMDb app; `imdbWebURL` is the fallback when it isn't installed.
    var imdbAppURL: URL? { imdbID.flatMap { URL(string: "imdb:///title/\($0)/") } }
    var imdbWebURL: URL? { imdbID.flatMap { URL(string: "https://www.imdb.com/title/\($0)/") } }
}

/// Works out which title a search is for, using IMDb's suggestions (ranked by popularity) and the
/// torrent names in the results, then looks the title up on Rotten Tomatoes.
actor TitleLookup {
    static let shared = TitleLookup()

    private var cache: [String: Task<TitleInfo?, Never>] = [:]

    func info(for query: String, results: [SearchResult]) async -> TitleInfo? {
        let key = query.lowercased()
        if let task = cache[key] { return await task.value }
        let task = Task { await Self.lookup(query: query, results: results) }
        cache[key] = task
        return await task.value
    }

    private static func lookup(query: String, results: [SearchResult]) async -> TitleInfo? {
        guard let typed = MediaQuery.parse(torrentName: query) else { return nil }
        let hint = hint(for: typed, from: results)

        let imdb = await (try? imdbSuggestions(for: typed.title)).flatMap { bestIMDb(for: hint, in: $0) }
        let title = imdb?.title ?? typed.title
        let year = imdb?.year ?? hint.year
        var scores: RTScores?
        if let imdb {
            scores = await RatingsService.shared.scores(for: MediaQuery(title: title, year: year, isTV: imdb.isTV))
        } else {
            // Without IMDb's answer we don't know the kind, so try the likelier one first.
            for isTV in [hint.isTV, !hint.isTV] where scores == nil {
                scores = await RatingsService.shared.scores(for: MediaQuery(title: title, year: year, isTV: isTV))
            }
        }
        guard imdb != nil || scores != nil else { return nil }
        return TitleInfo(title: scores?.title ?? title, year: year, isTV: imdb?.isTV ?? hint.isTV,
                         imdbID: imdb?.id, posterURL: imdb?.posterURL, scores: scores)
    }

    /// Refines the typed query with the results whose torrent names are for that title:
    /// the most common year, and whether they're mostly episodes.
    static func hint(for typed: MediaQuery, from results: [SearchResult]) -> MediaQuery {
        let wanted = normalize(typed.title)
        let matching = results.compactMap(\.mediaQuery).filter { normalize($0.title) == wanted }
        let tvVotes = matching.filter(\.isTV).count
        let isTV = typed.isTV || (!matching.isEmpty && tvVotes * 2 > matching.count)
        var year = typed.year
        if year == nil, !isTV {
            let counts = Dictionary(grouping: matching.compactMap(\.year), by: { $0 }).mapValues(\.count)
            year = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }
        return MediaQuery(title: typed.title, year: year, isTV: isTV)
    }

    // MARK: - IMDb

    /// The IMDb entry for a known title. `year` is a hint: when nothing matches it, the most popular
    /// entry with that title wins (a streaming date can be a year after the release).
    static func imdbTitle(title: String, year: Int?, isTV: Bool) async -> IMDbTitle? {
        guard let titles = try? await imdbSuggestions(for: title) else { return nil }
        if let year, let match = bestIMDb(for: MediaQuery(title: title, year: year, isTV: isTV), in: titles) {
            return match
        }
        return bestIMDb(for: MediaQuery(title: title, year: nil, isTV: isTV), in: titles)
    }

    struct IMDbTitle: Equatable, Sendable {
        let id: String
        let title: String
        let year: Int?
        let kind: String
        let posterURL: URL?

        var isTV: Bool { kind == "tvSeries" || kind == "tvMiniSeries" }
        var isMovie: Bool { kind == "movie" || kind == "tvMovie" }
        var appURL: URL? { URL(string: "imdb:///title/\(id)/") }
        var webURL: URL? { URL(string: "https://www.imdb.com/title/\(id)/") }
    }

    private struct Suggestions: Decodable {
        struct Entry: Decodable {
            struct Image: Decodable { let imageUrl: String }
            let id: String
            let l: String?
            let y: Int?
            let qid: String?
            let i: Image?
        }
        let d: [Entry]?
    }

    static func parseSuggestions(_ data: Data) throws -> [IMDbTitle] {
        try JSONDecoder().decode(Suggestions.self, from: data).d?.compactMap { entry in
            guard entry.id.hasPrefix("tt"), let title = entry.l, let kind = entry.qid else { return nil }
            // A width-limited rendition instead of the full-size original.
            let poster = entry.i.flatMap { URL(string: $0.imageUrl.replacingOccurrences(of: "._V1_.", with: "._V1_QL75_UX300_.")) }
            return IMDbTitle(id: entry.id, title: title, year: entry.y, kind: kind, posterURL: poster)
        } ?? []
    }

    private static func imdbSuggestions(for title: String) async throws -> [IMDbTitle] {
        let term = title.lowercased()
        guard let first = term.first(where: { $0.isLetter || $0.isNumber }),
              let url = URL(string: "https://v2.sg.media-imdb.com/suggestion/\(HTTP.encode(String(first)))/\(HTTP.encode(term)).json")
        else { return [] }
        return try parseSuggestions(try await HTTP.get(url))
    }

    /// The entry with the same title, preferring the matching kind and year; ties go to IMDb's order (most popular first).
    static func bestIMDb(for query: MediaQuery, in titles: [IMDbTitle]) -> IMDbTitle? {
        let wanted = normalize(query.title)
        return titles.enumerated().compactMap { rank, entry -> (IMDbTitle, Int)? in
            guard entry.isTV || entry.isMovie else { return nil }
            let title = normalize(entry.title)
            var score = 0
            if title == wanted { score += 4 } else if title.contains(wanted) { score += 1 } else { return nil }
            if query.isTV == entry.isTV { score += 1 }
            if let year = query.year, let entryYear = entry.year, !entry.isTV {
                score += year == entryYear ? 3 : abs(year - entryYear) == 1 ? 1 : -3
            }
            return score >= 4 ? (entry, score * 100 - rank) : nil
        }
        .max { $0.1 < $1.1 }?.0
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
