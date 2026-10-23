import Observation
import SwiftUI

/// The Rotten Tomatoes lists shown on the home screen, kept for the whole session so going back
/// from a search doesn't reload them.
@Observable
final class BrowseModel {
    enum Kind: String, CaseIterable, Identifiable {
        case movies = "Movies", tv = "TV Shows", watchlist = "Watchlist"
        var id: String { rawValue }
    }

    var kind: Kind = .movies
    var movieCategory: RTBrowse.Category = .moviesAtHome

    var category: RTBrowse.Category { kind == .tv ? .tvPopular : movieCategory }

    private(set) var lists: [RTBrowse.Category: [RTBrowseItem]] = [:]
    private(set) var errors: [RTBrowse.Category: String] = [:]
    private(set) var loading: Set<RTBrowse.Category> = []
    @ObservationIgnored private var pages: [RTBrowse.Category: Int] = [:]
    @ObservationIgnored private var exhausted: Set<RTBrowse.Category> = []

    var items: [RTBrowseItem] { lists[category] ?? [] }
    var isLoading: Bool { loading.contains(category) }
    var error: String? { errors[category] }

    /// Loads the first page of the current list, unless it's already loaded.
    func loadIfNeeded() async {
        if lists[category] == nil { await loadMore() }
    }

    func loadMore() async {
        let category = category
        guard !loading.contains(category), !exhausted.contains(category) else { return }
        // RT stops adding tiles after a few hundred; don't keep asking.
        let page = (pages[category] ?? 0) + 1
        guard page <= 10 else { exhausted.insert(category); return }
        loading.insert(category)
        defer { loading.remove(category) }
        do {
            let fetched = try await RTBrowse.fetch(category, page: page)
            let current = lists[category] ?? []
            let known = Set(current.map(\.id))
            let new = fetched.filter { !known.contains($0.id) }
            lists[category] = current + new
            pages[category] = page
            errors[category] = nil
            if new.isEmpty { exhausted.insert(category) }
        } catch {
            if lists[category] == nil { errors[category] = error.localizedDescription }
        }
    }

    func reload() async {
        let category = category
        lists[category] = nil
        pages[category] = nil
        exhausted.remove(category)
        await loadMore()
    }
}

/// Home screen: popular movies or TV shows from Rotten Tomatoes, or the watchlist.
struct BrowseView: View {
    @Bindable var model: BrowseModel
    let search: (TitleCardData) -> Void
    private var watchlist: Watchlist { .shared }

    var body: some View {
        List {
            if model.kind == .watchlist {
                watchlistRows
            } else {
                browseRows
            }
        }
        .listStyle(.plain)
        // Pinned right under the title bar; the list scrolls beneath it.
        .safeAreaBar(edge: .top) { header }
        .overlay { emptyState }
        .refreshable { if model.kind != .watchlist { await model.reload() } }
        .task(id: model.category) { if model.kind != .watchlist { await model.loadIfNeeded() } }
        .sensoryFeedback(.selection, trigger: model.kind)
        .sensoryFeedback(.selection, trigger: model.movieCategory)
    }

    @ViewBuilder private var browseRows: some View {
        ForEach(model.items) { item in
            let data = TitleCardData(item)
            TitleCard(data: data, search: { search(data) })
                .padding(.vertical, 4)
                .onAppear {
                    if item.id == model.items.last?.id { Task { await model.loadMore() } }
                }
        }
        if model.isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
        }
    }

    /// Saved titles, with the same cards as the lists. Swipe to remove.
    private var watchlistRows: some View {
        ForEach(watchlist.items) { data in
            TitleCard(data: data, search: { search(data) })
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        withAnimation { watchlist.remove(data) }
                    }
                }
        }
        .onDelete { watchlist.remove(atOffsets: $0) }
    }

    @ViewBuilder private var emptyState: some View {
        if model.kind == .watchlist {
            if watchlist.items.isEmpty {
                ContentUnavailableView("Watchlist Is Empty", systemImage: "plus.circle",
                                       description: Text("Tap ＋ next to a title to save it here."))
            }
        } else if let error = model.error, model.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Rotten Tomatoes", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }.buttonStyle(.glass)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $model.kind) {
                ForEach(BrowseModel.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.kind == .movies {
                Picker("Movies", selection: $model.movieCategory) {
                    ForEach([RTBrowse.Category.moviesAtHome, .moviesInTheaters]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
