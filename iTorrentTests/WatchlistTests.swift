import Foundation
import Testing
@testable import iTorrent

@MainActor
struct WatchlistTests {
    private func card(_ title: String, year: Int? = 2026, tv: Bool = false) -> TitleCardData {
        TitleCardData(RTBrowseItem(
            title: title,
            pageURL: URL(string: "https://www.rottentomatoes.com/\(tv ? "tv" : "m")/\(title.lowercased())_\(year ?? 0)")!,
            posterURL: nil, tomatometer: RTScores.Score(value: 98, isPositive: true, isCertified: true),
            popcornmeter: nil, date: "Streaming Oct 16, 2026", trailerID: "abc"))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "WatchlistTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func togglesAndPersists() {
        let defaults = freshDefaults()
        let list = Watchlist(defaults: defaults)
        let tenzing = card("Tenzing"), buddy = card("Buddy")
        list.toggle(tenzing)
        list.add(buddy)
        list.add(buddy) // no duplicates
        #expect(list.items.map(\.title) == ["Buddy", "Tenzing"])
        #expect(list.contains(tenzing))

        let reloaded = Watchlist(defaults: defaults)
        #expect(reloaded.items == list.items)
        #expect(reloaded.items.last?.rtTrailerURL == tenzing.rtTrailerURL)
        #expect(reloaded.items.last?.searchQuery == "Tenzing 2026")

        reloaded.toggle(tenzing)
        #expect(!reloaded.contains(tenzing))
        #expect(Watchlist(defaults: defaults).items.map(\.title) == ["Buddy"])
    }

    @Test func removesAtOffsets() {
        let list = Watchlist(defaults: freshDefaults())
        for title in ["A", "B", "C"] { list.add(card(title)) }
        list.remove(atOffsets: [0, 2])
        #expect(list.items.map(\.title) == ["B"])
    }
}
