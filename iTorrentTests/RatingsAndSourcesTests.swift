import Foundation
import Testing
@testable import iTorrent

struct MediaQueryTests {
    @Test(arguments: [
        ("Finch (2021) [1080p] [WEBRip] [5.1]", "Finch", 2021, false),
        ("The.Matrix.1999.1080p.BluRay.x264-GROUP", "The Matrix", 1999, false),
        ("1917.2019.2160p.UHD.BluRay.x265", "1917", 2019, false),
        ("Blade Runner 2049 (2017) 1080p", "Blade Runner 2049", 2017, false),
        ("The.Office.US.S03E05.720p.HDTV", "The Office", nil, true),
        ("[TGx] Dune Part Two 2024 1080p WEB-DL", "Dune Part Two", 2024, false),
        ("Breaking Bad Season 2 Complete 720p", "Breaking Bad", nil, true),
    ] as [(String, String, Int?, Bool)])
    func parsesTorrentNames(name: String, title: String, year: Int?, isTV: Bool) throws {
        let query = try #require(MediaQuery.parse(torrentName: name))
        #expect(query.title == title)
        #expect(query.year == year)
        #expect(query.isTV == isTV)
    }

    @Test func onlyVideoResultsGetRatings() {
        func result(_ type: String) -> SearchResult {
            SearchResult(infoHash: "X", name: "Finch (2021)", type: type, size: "1 GiB", uploader: "u",
                         magnet: URL(string: "magnet:?xt=urn:btih:X")!, sourceName: "s")
        }
        #expect(result("Video > HD - Movies").mediaQuery != nil)
        #expect(result("Applications > UNIX").mediaQuery == nil)
    }
}

struct RottenTomatoesParsingTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle(for: Token.self).url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func picksMovieWithMatchingYear() throws {
        let html = try fixture("rt-search.html")
        let match = try RatingsService.bestMatch(for: MediaQuery(title: "Finch", year: 2021, isTV: false), inSearchPage: html)
        #expect(match?.url.absoluteString == "https://www.rottentomatoes.com/m/finch")
        let older = try RatingsService.bestMatch(for: MediaQuery(title: "Finch", year: 1998, isTV: false), inSearchPage: html)
        #expect(older?.url.absoluteString == "https://www.rottentomatoes.com/m/finch_1998")
    }

    @Test func matchesTVOnlyToShows() throws {
        let html = try fixture("rt-search.html")
        let show = try RatingsService.bestMatch(for: MediaQuery(title: "The Office", year: nil, isTV: true), inSearchPage: html)
        #expect(show?.url.path() == "/tv/the_office")
        #expect(try RatingsService.bestMatch(for: MediaQuery(title: "The Office", year: nil, isTV: false), inSearchPage: html) == nil)
    }

    @Test func rejectsUnrelatedTitles() throws {
        let html = try fixture("rt-search.html")
        #expect(try RatingsService.bestMatch(for: MediaQuery(title: "Heat", year: 1995, isTV: false), inSearchPage: html) == nil)
    }

    @Test func readsBothScores() throws {
        let (critics, audience) = RatingsService.scores(inPage: try fixture("rt-movie.html"))
        #expect(critics == RTScores.Score(value: 74, isPositive: true, isCertified: true))
        #expect(audience == RTScores.Score(value: 68, isPositive: true, isCertified: false))
    }
}

struct SourceConfigTests {
    @Test func normalizesAddresses() {
        #expect(SourceConfig.normalizedURL(from: " tpb.party ")?.absoluteString == "https://tpb.party")
        #expect(SourceConfig.normalizedURL(from: "http://Mirror.Example.org/search/x/1/99/0?y=1")?.absoluteString == "http://mirror.example.org")
        #expect(SourceConfig.normalizedURL(from: "not a url") == nil)
        #expect(SourceConfig.normalizedURL(from: "ftp://x.org") == nil)
    }

    @Test func guessesKind() {
        #expect(SourceConfig.guessKind(for: URL(string: "https://thepiratebay.org")!) == .api)
        #expect(SourceConfig.guessKind(for: URL(string: "https://apibay.org")!) == .api)
        #expect(SourceConfig.guessKind(for: URL(string: "https://thepiratebay10.org")!) == .html)
    }

    @Test func mainSiteUsesApibayBackend() {
        let source = SourceConfig(url: URL(string: "https://thepiratebay.org")!, kind: .api).makeSource() as? ApiBaySource
        #expect(source?.baseURL.host() == "apibay.org")
        #expect(source?.name == "thepiratebay.org")
    }
}

private final class Token {}
