import Foundation
import Testing
@testable import iTorrent

struct TitleLookupTests {
    private func result(_ name: String, type: String = "Video > HD - Movies") -> SearchResult {
        SearchResult(infoHash: UUID().uuidString, name: name, type: type, size: "1 GiB", uploader: "x",
                     magnet: URL(string: "magnet:?xt=urn:btih:00")!, sourceName: "test")
    }

    private let imdbJSON = Data("""
    {"d":[
      {"id":"tt0133093","l":"The Matrix","y":1999,"qid":"movie","i":{"imageUrl":"https://m.media-amazon.com/images/M/abc._V1_.jpg"}},
      {"id":"in0000304","l":"The Matrix"},
      {"id":"tt0234215","l":"The Matrix Reloaded","y":2003,"qid":"movie"},
      {"id":"tt10838180","l":"The Matrix Resurrections","y":2021,"qid":"movie"},
      {"id":"tt0410519","l":"The Matrix Recalibrated","y":2004,"qid":"video"}
    ]}
    """.utf8)

    @Test func parsesIMDbSuggestions() throws {
        let titles = try TitleLookup.parseSuggestions(imdbJSON)
        #expect(titles.map(\.id) == ["tt0133093", "tt0234215", "tt10838180", "tt0410519"])
        #expect(titles[0].posterURL?.absoluteString == "https://m.media-amazon.com/images/M/abc._V1_QL75_UX300_.jpg")
    }

    @Test func picksExactTitleAndYear() throws {
        let titles = try TitleLookup.parseSuggestions(imdbJSON)
        let match = TitleLookup.bestIMDb(for: MediaQuery(title: "the matrix", year: nil, isTV: false), in: titles)
        #expect(match?.id == "tt0133093")
        let reloaded = TitleLookup.bestIMDb(for: MediaQuery(title: "the matrix reloaded", year: 2003, isTV: false), in: titles)
        #expect(reloaded?.id == "tt0234215")
        #expect(TitleLookup.bestIMDb(for: MediaQuery(title: "finch", year: nil, isTV: false), in: titles) == nil)
    }

    @Test func prefersSeriesWhenResultsAreEpisodes() {
        let office = [
            TitleLookup.IMDbTitle(id: "tt1", title: "The Office", year: 2019, kind: "movie", posterURL: nil),
            TitleLookup.IMDbTitle(id: "tt0386676", title: "The Office", year: 2005, kind: "tvSeries", posterURL: nil),
        ]
        let hint = TitleLookup.hint(for: MediaQuery(title: "the office", year: nil, isTV: false), from: [
            result("The Office US S05E07 1080p WEB-DL", type: "Video > HD - TV shows"),
            result("The.Office.US.S09.COMPLETE.720p", type: "Video > TV shows"),
        ])
        #expect(hint.isTV)
        #expect(TitleLookup.bestIMDb(for: hint, in: office)?.id == "tt0386676")
    }

    @Test func takesMostCommonYearFromResults() {
        let hint = TitleLookup.hint(for: MediaQuery(title: "the matrix", year: nil, isTV: false), from: [
            result("The Matrix (1999) 1080p BrRip x264 - YIFY"),
            result("The.Matrix.1999.1080p.BluRay.x265"),
            result("The Matrix Resurrections (2021) [1080p]"),
            result("The Matrix 2021 rumor cam"),
            result("The.Matrix.1999.REMASTERED.2160p"),
        ])
        #expect(hint.year == 1999)
        #expect(!hint.isTV)
    }
}

/// Opt-in: `TEST_RUNNER_RUN_NETWORK_TESTS=1`.
struct LiveTitleLookupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"))
    func findsTheMatrix() async throws {
        let results = try await PirateBayHTMLSource().fetchPage(query: "the matrix", page: 1).results
        let info = try #require(await TitleLookup.shared.info(for: "the matrix", results: results))
        print("LIVE title=\(info.title) year=\(info.year ?? 0) imdb=\(info.imdbID ?? "-") rt=\(String(describing: info.scores))")
        #expect(info.imdbID == "tt0133093")
        #expect(info.year == 1999)
        #expect(info.scores?.tomatometer != nil)
        #expect(info.scores?.popcornmeter != nil)
    }
}

struct IMDbDetailsTests {
    @Test func parsesGraphQLResponse() throws {
        let json = Data("""
        {"data":{"title":{"id":"tt0133093","titleType":{"canHaveEpisodes":false},
          "ratingsSummary":{"aggregateRating":8.7,"voteCount":2288871},
          "plot":{"plotText":{"plainText":"A computer hacker discovers that his life is a simulation."}},
          "genres":{"genres":[{"text":"Action"},{"text":"Sci-Fi"}]},
          "runtime":{"seconds":8160},
          "primaryImage":{"url":"https://m.media-amazon.com/images/M/abc._V1_.jpg"},
          "principalCredits":[
            {"category":{"id":"director"},"credits":[{"name":{"nameText":{"text":"Lana Wachowski"}}},{"name":{"nameText":{"text":"Lilly Wachowski"}}}]},
            {"category":{"id":"writer"},"credits":[{"name":{"nameText":{"text":"Lilly Wachowski"}}}]},
            {"category":{"id":"cast"},"credits":[{"name":{"nameText":{"text":"Keanu Reeves"}}},{"name":{"nameText":{"text":"Laurence Fishburne"}}}]}],
          "primaryVideos":{"edges":[{"node":{"playbackURLs":[
            {"url":"https://imdb-video.media-imdb.com/a.mp4","videoMimeType":"MP4"},
            {"url":"https://imdb-video.media-imdb.com/master.m3u8","videoMimeType":"M3U8"}]}}]}}}}
        """.utf8)
        let details = try #require(try IMDbService.parse(json))
        #expect(details.rating == 8.7)
        #expect(details.directors == ["Lana Wachowski", "Lilly Wachowski"])
        #expect(details.stars == ["Keanu Reeves", "Laurence Fishburne"])
        #expect(details.genres == ["Action", "Sci-Fi"])
        #expect(details.runtimeMinutes == 136)
        #expect(details.trailerURL?.absoluteString == "https://imdb-video.media-imdb.com/master.m3u8")
        #expect(details.posterURL?.absoluteString == "https://m.media-amazon.com/images/M/abc._V1_QL75_UX300_.jpg")
        #expect(!details.isTV)
    }

    @Test func seriesUseCreators() throws {
        let json = Data("""
        {"data":{"title":{"id":"tt0386676","titleType":{"canHaveEpisodes":true},
          "principalCredits":[{"category":{"id":"creator"},"credits":[{"name":{"nameText":{"text":"Greg Daniels"}}}]}]}}}
        """.utf8)
        let details = try #require(try IMDbService.parse(json))
        #expect(details.directors == ["Greg Daniels"])
        #expect(details.isTV)
        #expect(details.rating == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"))
    func fetchesLiveDetails() async throws {
        let details = try #require(await IMDbService.shared.details(for: "tt0133093"))
        #expect((details.rating ?? 0) > 7)
        #expect(details.directors.contains("Lana Wachowski"))
        #expect(details.stars.contains("Keanu Reeves"))
        #expect(details.plot?.isEmpty == false)
        #expect(details.trailerURL != nil)
    }
}
