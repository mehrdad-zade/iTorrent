import Foundation
import Testing
@testable import iTorrent

private final class FixtureToken {}

struct RTBrowseTests {
    @Test func parsesBrowseTiles() throws {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: "rt-browse.html", withExtension: nil))
        let items = try RTBrowse.parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
        #expect(items.count >= 20)
        #expect(Set(items.map(\.id)).count == items.count)

        let first = try #require(items.first)
        #expect(first.title == "You Can See Everything")
        #expect(first.pageURL.absoluteString == "https://www.rottentomatoes.com/m/you_can_see_everything")
        #expect(first.tomatometer == RTScores.Score(value: 97, isPositive: true, isCertified: true))
        #expect(first.popcornmeter?.value == 97)
        #expect(first.date == "Opened Oct 16, 2026")
        #expect(first.trailerURL?.absoluteString
                == "https://link.theplatform.com/s/NGweTC/media/7e5Lu9QAAqrs?formats=M3U+none&format=redirect")
        #expect(first.posterURL != nil)
        #expect(!first.isTV)
    }

    @Test func readsYearFromSlugOrDate() {
        func item(_ path: String, date: String?) -> RTBrowseItem {
            RTBrowseItem(title: "X", pageURL: URL(string: "https://www.rottentomatoes.com\(path)")!, posterURL: nil,
                         tomatometer: nil, popcornmeter: nil, date: date, trailerID: nil)
        }
        #expect(item("/m/street_fighter_2026", date: "Opened Oct 16, 2027").year == 2026)
        #expect(item("/m/tenzing", date: "Streaming Oct 16, 2026").year == 2026)
        #expect(item("/tv/carrie", date: nil).year == nil)
    }

    @Test func addsSlugYearToSearch() {
        func item(_ title: String, _ path: String) -> RTBrowseItem {
            RTBrowseItem(title: title, pageURL: URL(string: "https://www.rottentomatoes.com\(path)")!, posterURL: nil,
                         tomatometer: nil, popcornmeter: nil, date: nil, trailerID: nil)
        }
        #expect(item("Street Fighter", "/m/street_fighter_2026").searchQuery == "Street Fighter 2026")
        #expect(item("Tenzing", "/m/tenzing").searchQuery == "Tenzing")
        #expect(item("Blade Runner 2049", "/m/blade_runner_2049").searchQuery == "Blade Runner 2049")
        #expect(item("Carrie", "/tv/carrie_2026").searchQuery == "Carrie")
    }
}

/// Opt-in: `TEST_RUNNER_RUN_NETWORK_TESTS=1`.
struct LiveRTBrowseTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"),
          arguments: RTBrowse.Category.allCases)
    func loadsLiveList(_ category: RTBrowse.Category) async throws {
        let items = try await RTBrowse.fetch(category, page: 1)
        print("LIVE \(category): \(items.count) e.g. \(items.prefix(3).map(\.title))")
        #expect(items.count >= 20)
        #expect(items.allSatisfy { $0.isTV == category.isTV })
        #expect(items.filter { $0.tomatometer != nil || $0.popcornmeter != nil }.count >= 10)
        #expect(items.contains { $0.trailerURL != nil })

        // The IMDb button looks titles up by name and year.
        let first = try #require(items.first)
        let imdb = await TitleLookup.imdbTitle(title: first.title, year: first.year, isTV: first.isTV)
        print("LIVE IMDb for \(first.title) (\(first.year ?? 0)): \(imdb?.id ?? "none") \(imdb?.title ?? "") \(imdb?.year ?? 0)")
        #expect(imdb != nil)
    }
}
