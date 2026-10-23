import SwiftUI

struct SearchView: View {
    @AppStorage(Consent.onboardingKey) private var onboardingComplete = false

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var pager: SearchPager?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errors: [String] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showPermissions = false
    @State private var titleInfo: TitleInfo?
    @State private var titleTask: Task<Void, Never>?
    /// The card a search was started from (a list or watchlist title), which becomes the header as is.
    @State private var origin: TitleCardData?
    @State private var browse = BrowseModel()
    @State private var pickedFromBrowse = 0
    @State private var wentHome = 0

    var body: some View {
        NavigationStack {
            Group {
                if pager == nil {
                    BrowseView(model: browse) { item in
                        pickedFromBrowse += 1
                        query = item.searchQuery
                        startSearch(from: item)
                    }
                } else {
                    resultsList
                }
            }
            .navigationTitle("iTorrent")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search torrents")
            .onSubmit(of: .search) { startSearch() }
            .onChange(of: query) { _, new in
                // Clearing the search field (or tapping Cancel) goes back to the Rotten Tomatoes lists.
                if new.isEmpty { clearSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                if pager != nil {
                    // Back to the Rotten Tomatoes lists from the search results.
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Home", systemImage: "house") {
                            query = ""
                            clearSearch()
                            wentHome += 1
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Downloads", systemImage: "arrow.down.circle") { showDownloads = true }
                }
                // iOS 26: puts the search field in the Liquid Glass bottom toolbar.
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            .sheet(isPresented: $showDownloads) { DownloadsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPermissions) { PermissionsView() }
            .fullScreenCover(isPresented: .constant(!onboardingComplete)) { PermissionsView(isOnboarding: true) }
            .sensoryFeedback(.impact(weight: .light), trigger: pager?.query) { _, new in new != nil }
            .sensoryFeedback(.selection, trigger: results.count) { old, new in new > old && old > 0 }
            .sensoryFeedback(.warning, trigger: errors) { _, new in !new.isEmpty && results.isEmpty }
            .sensoryFeedback(.impact(weight: .medium), trigger: pickedFromBrowse)
            .sensoryFeedback(.impact(weight: .light), trigger: wentHome)
        }
    }

    private var resultsList: some View {
        List {
            if let header = origin ?? titleInfo.map(TitleCardData.init) {
                TitleCard(data: header, plotLineLimit: nil)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(results) { result in
                ResultRow(result: result, needsConsent: { showPermissions = true })
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if hasMore && !results.isEmpty {
                Button("Load More", systemImage: "arrow.down.circle", action: loadMore)
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
    }

    @ViewBuilder private var emptyState: some View {
        if results.isEmpty && !isLoading {
            if !errors.isEmpty {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(errors.joined(separator: "\n")))
            } else {
                ContentUnavailableView.search(text: pager?.query ?? query)
            }
        }
    }

    private func clearSearch() {
        loadTask?.cancel()
        titleTask?.cancel()
        pager = nil
        results = []
        errors = []
        titleInfo = nil
        origin = nil
        hasMore = false
        isLoading = false
    }

    private func startSearch(from item: TitleCardData? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loadTask?.cancel()
        titleTask?.cancel()
        titleInfo = nil
        results = []
        errors = []
        origin = item
        let sources = SourceStore.shared.makeSources()
        pager = SearchPager(query: trimmed, sources: sources)
        if sources.isEmpty {
            errors = ["No search sources. Add one in Settings."]
            hasMore = false
            return
        }
        loadMore()
    }

    private func loadMore() {
        guard let pager else { return }
        isLoading = true
        loadTask = Task {
            do {
                let page = try await pager.loadNext()
                let isFirstPage = results.isEmpty
                results += page
                if isFirstPage { lookUpTitle(query: pager.query, results: page) }
            } catch {
                return // cancelled by a newer search, which now owns the UI state
            }
            hasMore = pager.hasMore
            errors = pager.errors
            isLoading = false
        }
    }

    /// Looks up the movie or show for the header once the first page shows what the search is for.
    private func lookUpTitle(query: String, results: [SearchResult]) {
        // A search from a Rotten Tomatoes title already has its header. Otherwise only video searches
        // get one: "ubuntu" shouldn't get a movie header.
        guard origin == nil, results.filter({ $0.type.hasPrefix("Video") }).count * 2 > results.count else { return }
        titleTask = Task {
            guard let info = await TitleLookup.shared.info(for: query, results: results),
                  !Task.isCancelled, pager?.query == query else { return }
            withAnimation(.smooth) { titleInfo = info }
        }
    }
}
