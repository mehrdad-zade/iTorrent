import Foundation
import Testing
@testable import iTorrent

private struct MockSource: TorrentSource {
    let name: String
    let total: Int
    let perPage: Int
    var failing = false

    func fetchPage(query: String, page: Int) async throws -> SourcePage {
        if failing { throw URLError(.notConnectedToInternet) }
        let start = (page - 1) * perPage
        let end = min(start + perPage, total)
        let results = (start..<max(start, end)).map { i in
            SearchResult(infoHash: "\(name)-\(i)", name: "\(name) \(i)", type: "Video", size: "1 GiB",
                         uploader: "u", magnet: URL(string: "magnet:?xt=urn:btih:\(i)")!, sourceName: name)
        }
        return SourcePage(results: results, hasMore: end < total)
    }
}

@MainActor
struct SearchPagerTests {
    @Test func drainsFirstSourceBeforeSecond() async throws {
        let pager = SearchPager(query: "q", sources: [MockSource(name: "A", total: 25, perPage: 30),
                                                       MockSource(name: "B", total: 40, perPage: 100)])
        let sourcesPerPage = try await (0..<8).asyncMap { _ in try await pager.loadNext().map(\.sourceName) }
        #expect(sourcesPerPage[0] == Array(repeating: "A", count: 10))
        #expect(sourcesPerPage[1] == Array(repeating: "A", count: 10))
        #expect(sourcesPerPage[2] == Array(repeating: "A", count: 5) + Array(repeating: "B", count: 5))
        #expect(sourcesPerPage[3] == Array(repeating: "B", count: 10))
        #expect(sourcesPerPage[5] == Array(repeating: "B", count: 10))
        #expect(sourcesPerPage[6] == Array(repeating: "B", count: 5)) // 25 + 40 = 65 results in total
        #expect(sourcesPerPage[7].isEmpty)
        #expect(!pager.hasMore)
    }

    @Test func keepsPagingFirstSourceAcrossItsPages() async throws {
        let pager = SearchPager(query: "q", sources: [MockSource(name: "A", total: 45, perPage: 8),
                                                       MockSource(name: "B", total: 10, perPage: 10)])
        var all: [SearchResult] = []
        while pager.hasMore { all += try await pager.loadNext() }
        #expect(all.prefix(45).allSatisfy { $0.sourceName == "A" })
        #expect(all.count == 55)
    }

    @Test func skipsFailingSourceAndDeduplicates() async throws {
        let dupe = MockSource(name: "A", total: 5, perPage: 5)
        let pager = SearchPager(query: "q", sources: [MockSource(name: "X", total: 0, perPage: 1, failing: true), dupe, dupe])
        let page = try await pager.loadNext()
        #expect(page.count == 5)
        #expect(pager.errors.count == 1)
        #expect(!pager.hasMore)
    }
}

struct ParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    @Test func parsesHTMLResults() throws {
        let html = String(decoding: try fixture("search.html"), as: UTF8.self)
        let page = try PirateBayHTMLSource().parse(html)
        #expect(page.hasMore)
        #expect(page.results.count == 2)
        let first = page.results[0]
        #expect(first.name == "Big Buck Bunny 1080p")
        #expect(first.type == "Video > HD - Movies")
        #expect(first.size == "2.13 GiB")
        #expect(first.uploader == "blender")
        #expect(first.infoHash == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C")
        #expect(page.results[1].uploader == "Anonymous")
        #expect(page.results[1].type == "Applications > UNIX")
    }

    @Test func parsesApiBayResults() throws {
        let page = try ApiBaySource().parse(try fixture("apibay.json"))
        #expect(!page.hasMore)
        #expect(page.results.count == 2)
        #expect(page.results[0].type == "Video > HD - Movies")
        #expect(page.results[0].infoHash == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C")
        #expect(page.results[0].uploader == "blender")
        #expect(page.results[0].size == "2.13 GB" || page.results[0].size == "2.13 GiB")
        #expect(page.results[1].type == "Other > Other")
    }

    @Test func treatsSentinelAsNoResults() throws {
        let json = #"[{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000","leechers":"0","seeders":"0","size":"0","num_files":"0","username":"","added":"0","status":"member","category":"0","imdb":""}]"#
        let page = try ApiBaySource().parse(Data(json.utf8))
        #expect(page.results.isEmpty)
    }

    @Test func normalizesBase32Hash() {
        #expect(InfoHash.from(magnet: "magnet:?xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4")
                == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C")
    }

    @Test func encodesMultiWordQueryOnce() {
        let url = PirateBayHTMLSource().searchURL(query: "the matrix", page: 2)
        #expect(url?.absoluteString == "https://thepiratebay0.org/search/the%20matrix/2/99/0")
        let custom = PirateBayHTMLSource(baseURL: URL(string: "https://example.org/")!)
        #expect(custom.searchURL(query: "a/b & c", page: 1)?.absoluteString
                == "https://example.org/search/a%2Fb%20%26%20c/1/99/0")
    }
}

private final class BundleToken {}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}

/// Hits the real sites. Opt-in like `EngineSmokeTests`: `TEST_RUNNER_RUN_NETWORK_TESTS=1`.
@MainActor
struct LiveSearchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"))
    func pagesThroughLiveSources() async throws {
        let sources: [any TorrentSource] = [PirateBayHTMLSource(), ApiBaySource()]
        let pager = SearchPager(query: "ubuntu", sources: sources)
        let first = try await pager.loadNext()
        let second = try await pager.loadNext()
        print("LIVE errors=\(pager.errors) first=\(first.map(\.sourceName)) sample=\(first.first.map { "\($0.name) | \($0.type) | \($0.size) | \($0.uploader)" } ?? "-")")
        #expect(first.count == 10)
        #expect(second.count == 10)
        #expect(first.allSatisfy { $0.sourceName == "thepiratebay0.org" })
        #expect(Set((first + second).map(\.infoHash)).count == 20)
        #expect(first.allSatisfy { !$0.size.isEmpty && !$0.uploader.isEmpty && !$0.type.isEmpty })

        let fallback = try await SearchPager(query: "ubuntu", sources: [ApiBaySource()]).loadNext()
        print("LIVE apibay sample=\(fallback.first.map { "\($0.name) | \($0.type) | \($0.size) | \($0.uploader)" } ?? "-")")
        #expect(fallback.count == 10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"))
    func multiWordQueryReturnsRelevantResults() async throws {
        for source in [PirateBayHTMLSource(), ApiBaySource()] as [any TorrentSource] {
            let results = try await source.fetchPage(query: "the matrix", page: 1).results
            print("LIVE \(source.name): \(results.prefix(3).map(\.name))")
            #expect(!results.isEmpty)
            #expect(results.prefix(10).allSatisfy { $0.name.localizedCaseInsensitiveContains("matrix") })
        }
    }
}

struct LiveRatingsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"),
          arguments: ["Finch (2021) [1080p] [WEBRip] [5.1]", "The.Office.US.S03E05.720p.HDTV.x264"])
    func fetchesRottenTomatoesScores(torrentName: String) async throws {
        let query = try #require(MediaQuery.parse(torrentName: torrentName))
        let scores = try #require(await RatingsService.shared.scores(for: query))
        print("LIVE RT \(torrentName) -> \(scores.title) \(scores.pageURL.path()) tomatometer=\(scores.tomatometer?.value ?? -1) popcornmeter=\(scores.popcornmeter?.value ?? -1)")
        #expect(scores.tomatometer != nil)
        #expect(scores.popcornmeter != nil)
    }
}
