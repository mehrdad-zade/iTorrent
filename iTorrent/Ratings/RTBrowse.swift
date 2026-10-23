import Foundation
import SwiftSoup

/// One movie or show from a Rotten Tomatoes browse list.
nonisolated struct RTBrowseItem: Identifiable, Hashable, Sendable {
    let title: String
    let pageURL: URL
    let posterURL: URL?
    let tomatometer: RTScores.Score?
    let popcornmeter: RTScores.Score?
    /// "Opened Oct 16, 2026", "Streaming Oct 10, 2026", "Latest Episode: …".
    let date: String?
    /// theplatform.com media ID for the trailer, when RT has one.
    let trailerID: String?

    var id: URL { pageURL }
    var isTV: Bool { pageURL.path().hasPrefix("/tv/") }

    var scores: RTScores { RTScores(title: title, pageURL: pageURL, tomatometer: tomatometer, popcornmeter: popcornmeter) }

    /// An unencrypted HLS stream AVPlayer can play.
    var trailerURL: URL? {
        trailerID.flatMap { URL(string: "https://link.theplatform.com/s/NGweTC/media/\($0)?formats=M3U+none&format=redirect") }
    }

    /// Release year from the slug ("/m/street_fighter_2026"), otherwise the year in the date line.
    var year: Int? {
        let slug = pageURL.lastPathComponent
        if let range = slug.range(of: #"_(19|20)\d\d$"#, options: .regularExpression) {
            return Int(slug[range].dropFirst())
        }
        return date.flatMap { date in
            date.range(of: #"(19|20)\d\d"#, options: .regularExpression).flatMap { Int(date[$0]) }
        }
    }

    /// What to search the torrent sites for. RT puts the year in the slug ("/m/street_fighter_2026")
    /// when titles clash, and torrent names carry the year, so add it when it's there.
    var searchQuery: String {
        let slug = pageURL.lastPathComponent
        if !isTV, let range = slug.range(of: #"_(19|20)\d\d$"#, options: .regularExpression),
           !title.contains(slug[range].dropFirst()) {
            return "\(title) \(slug[range].dropFirst())"
        }
        return title
    }
}

/// Rotten Tomatoes' browse pages, scraped from HTML (there's no public API).
nonisolated enum RTBrowse {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case moviesAtHome = "movies_at_home"
        case moviesInTheaters = "movies_in_theaters"
        case tvPopular = "tv_series_browse"

        var id: String { rawValue }
        var isTV: Bool { self == .tvPopular }
        var title: String {
            switch self {
            case .moviesAtHome: "Streaming & At Home"
            case .moviesInTheaters: "In Theaters"
            case .tvPopular: "Popular TV"
            }
        }
    }

    /// Each page holds every tile up to it (page 2 = tiles 1–56), so the caller keeps the new ones.
    nonisolated static func fetch(_ category: Category, page: Int) async throws -> [RTBrowseItem] {
        var url = URL(string: "https://www.rottentomatoes.com/browse/\(category.rawValue)/sort:popular")!
        if page > 1 { url.append(queryItems: [URLQueryItem(name: "page", value: String(page))]) }
        return try parse(String(decoding: try await HTTP.get(url), as: UTF8.self))
    }

    nonisolated static func parse(_ html: String) throws -> [RTBrowseItem] {
        let base = URL(string: "https://www.rottentomatoes.com")!
        var seen = Set<URL>()
        return try SwiftSoup.parse(html).select("media-info-tile").array().compactMap { tile in
            guard let poster = try tile.select("poster-tile").first(),
                  let page = URL(string: try poster.attr("media-url"), relativeTo: base)?.absoluteURL,
                  seen.insert(page).inserted
            else { return nil }
            let title = try tile.select("[data-qa=discovery-media-list-item-title]").first()?.text()
                ?? (try tile.select("rt-img").first()?.attr("alt")) ?? ""
            guard !title.isEmpty else { return nil }
            let date = try tile.select("[data-qa=discovery-media-list-item-start-date]").first()?.text()
            let trailer = try tile.select("play-button").first()?.attr("data-public-id")
            return RTBrowseItem(
                title: title,
                pageURL: page,
                posterURL: URL(string: try tile.select("rt-img").first()?.attr("src") ?? ""),
                tomatometer: try score(in: tile, slot: "criticsScore", icon: "score-icon-critics"),
                popcornmeter: try score(in: tile, slot: "audienceScore", icon: "score-icon-audience"),
                date: date.flatMap { $0.isEmpty ? nil : $0 },
                trailerID: trailer.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private nonisolated static func score(in tile: Element, slot: String, icon: String) throws -> RTScores.Score? {
        let text = try tile.select("rt-text[slot=\(slot)]").first()?.text() ?? ""
        guard let value = Int(text.filter(\.isNumber)) else { return nil }
        let iconElement = try tile.select(icon).first()
        let sentiment = try iconElement?.attr("sentiment") ?? ""
        return RTScores.Score(value: value,
                              isPositive: sentiment.isEmpty ? value >= 60 : sentiment == "positive",
                              isCertified: try iconElement?.attr("certified") == "true")
    }
}
