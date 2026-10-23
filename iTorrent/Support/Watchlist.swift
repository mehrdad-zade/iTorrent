import Foundation
import Observation

/// Titles the user saved from a card's ＋ button, newest first. Kept in UserDefaults.
@Observable
final class Watchlist {
    static let shared = Watchlist()

    private(set) var items: [TitleCardData] = []
    @ObservationIgnored private let key = "watchlist"
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([TitleCardData].self, from: data) {
            items = saved
        }
    }

    func contains(_ item: TitleCardData) -> Bool { items.contains { $0.id == item.id } }

    func toggle(_ item: TitleCardData) {
        if contains(item) { remove(item) } else { add(item) }
    }

    func add(_ item: TitleCardData) {
        guard !contains(item) else { return }
        items.insert(item, at: 0)
        save()
    }

    func remove(_ item: TitleCardData) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) { items.remove(at: index) }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
