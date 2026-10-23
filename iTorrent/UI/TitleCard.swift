import AVKit
import SwiftUI

/// What a title card starts with: either a Rotten Tomatoes list entry or a search's title lookup.
/// The card fills in the rest (IMDb rating, credits, plot, trailer) itself.
nonisolated struct TitleCardData: Identifiable, Hashable, Codable, Sendable {
    let title: String
    /// What Pirate Search looks for on the torrent sites.
    let searchQuery: String
    /// "Streaming Oct 9, 2026", or "1999 · Movie".
    let subtitle: String?
    let year: Int?
    let isTV: Bool
    let posterURL: URL?
    let rtTrailerURL: URL?
    let tomatometer: RTScores.Score?
    let popcornmeter: RTScores.Score?
    /// Known when the card comes from a title lookup; otherwise found from the title and year.
    let imdbID: String?

    var id: String { "\(title)|\(year ?? 0)|\(isTV)" }

    init(_ item: RTBrowseItem) {
        title = item.title
        searchQuery = item.searchQuery
        subtitle = item.date
        year = item.year
        isTV = item.isTV
        posterURL = item.posterURL
        rtTrailerURL = item.trailerURL
        tomatometer = item.tomatometer
        popcornmeter = item.popcornmeter
        imdbID = nil
    }

    init(_ info: TitleInfo) {
        title = info.title
        searchQuery = [info.title, info.isTV ? nil : info.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
        subtitle = [info.year.map(String.init), info.isTV ? "TV Series" : "Movie"].compactMap { $0 }.joined(separator: " · ")
        year = info.year
        isTV = info.isTV
        posterURL = info.posterURL
        rtTrailerURL = nil
        tomatometer = info.scores?.tomatometer
        popcornmeter = info.scores?.popcornmeter
        imdbID = info.imdbID
    }
}

/// Poster (tap for the trailer), title, scores, IMDb rating, director, stars, summary,
/// and buttons for IMDb and, on the home screen, Pirate Search.
struct TitleCard: View {
    let data: TitleCardData
    /// Shows the Pirate Search button. Nil on the card above the search results.
    var search: (() -> Void)?
    /// The home screen shows a few lines of the plot; tapping expands it.
    var plotLineLimit: Int? = 3

    @Environment(\.openURL) private var openURL
    @State private var imdb: IMDbDetails?
    @State private var lookedUp = false
    @State private var showPlot = false
    @State private var playing: URL?
    @State private var openedIMDb = 0
    private var watchlist: Watchlist { .shared }

    private var trailerURL: URL? { data.rtTrailerURL ?? imdb?.trailerURL }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                poster
                buttons
            }
            .frame(width: 80)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    watchlistButton
                    Text(data.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                if let line = infoLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                scores
                credits
                if let plot = imdb?.plot {
                    Text(plot)
                        .font(.caption)
                        .lineLimit(showPlot ? nil : plotLineLimit)
                        .onTapGesture { withAnimation(.snappy) { showPlot.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(showPlot ? "Collapses the summary" : "Shows the full summary")
                }
            }
            Spacer(minLength: 0)
        }
        .task(id: data.id) { await loadIMDb() }
        .fullScreenCover(item: $playing) { url in TrailerPlayer(title: data.title, url: url) }
        .sensoryFeedback(.impact(weight: .light), trigger: openedIMDb)
    }

    /// ＋ adds the card to the watchlist; ✓ removes it.
    private var watchlistButton: some View {
        let saved = watchlist.contains(data)
        return Button {
            withAnimation(.snappy) { watchlist.toggle(data) }
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(saved ? .green : .accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(saved ? .success : .impact(weight: .light), trigger: saved)
        .accessibilityLabel(saved ? "Remove \(data.title) from Watchlist" : "Add \(data.title) to Watchlist")
    }

    /// "Streaming Oct 9, 2026 · Action, Sci-Fi · 2h 16m"
    private var infoLine: String? {
        var parts: [String] = []
        if let subtitle = data.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let genres = imdb?.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        if let minutes = imdb?.runtimeMinutes, minutes > 0, !(imdb?.isTV ?? data.isTV) {
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var poster: some View {
        let image = AsyncImage(url: data.posterURL ?? imdb?.posterURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: data.isTV ? "tv" : "film").foregroundStyle(.secondary)
        }
        .frame(width: 80, height: 120)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 10))

        if let trailerURL {
            Button { playing = trailerURL } label: {
                image.overlay {
                    Image(systemName: "play.fill")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.45), in: .circle)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play \(data.title) trailer")
        } else {
            image.accessibilityHidden(true)
        }
    }

    /// Plain text: "🍅 98%   🍿 91%   ⭐ 8.7".
    @ViewBuilder private var scores: some View {
        let parts = [
            data.tomatometer.map { "\($0.isPositive ? "🍅" : "🤢") \($0.value)%" },
            data.popcornmeter.map { "\($0.isPositive ? "🍿" : "🫗") \($0.value)%" },
            imdb?.rating.map { "⭐ \($0.formatted(.number.precision(.fractionLength(1))))" },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "   "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel([
                    data.tomatometer.map { "Tomatometer \($0.value) percent" },
                    data.popcornmeter.map { "Popcornmeter \($0.value) percent" },
                    imdb?.rating.map { "IMDb rating \($0.formatted()) out of 10" },
                ].compactMap { $0 }.joined(separator: ", "))
        }
    }

    @ViewBuilder private var credits: some View {
        if let imdb {
            if !imdb.directors.isEmpty {
                credit(imdb.isTV ? "Created by" : "Director", imdb.directors.prefix(2).joined(separator: ", "))
            }
            if !imdb.stars.isEmpty {
                credit("Stars", imdb.stars.prefix(3).joined(separator: ", "))
            }
        }
    }

    private func credit(_ label: String, _ names: String) -> some View {
        Text("\(Text(label).foregroundStyle(.secondary)) \(names)")
            .font(.caption)
            .lineLimit(2)
    }

    /// Stacked under the poster, each as wide as it.
    private var buttons: some View {
        VStack(spacing: 6) {
            if let search {
                Button(action: search) { Text("Pirate").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Search torrents for \(data.title)")
            }
            if let id = imdb?.id ?? data.imdbID {
                Button { openIMDb(id) } label: { Text("IMDb").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
                    .accessibilityLabel("Open \(data.title) in IMDb")
            } else if !lookedUp {
                ProgressView().controlSize(.mini)
            }
        }
        .controlSize(.small)
        .font(.caption.weight(.semibold))
    }

    private func loadIMDb() async {
        let id: String?
        if let known = data.imdbID {
            id = known
        } else {
            id = await TitleLookup.imdbTitle(title: data.title, year: data.year, isTV: data.isTV)?.id
        }
        if let id, let details = await IMDbService.shared.details(for: id) {
            withAnimation(.smooth) { imdb = details }
        }
        lookedUp = true
    }

    private func openIMDb(_ id: String) {
        openedIMDb += 1
        guard let app = URL(string: "imdb:///title/\(id)/"), let web = URL(string: "https://www.imdb.com/title/\(id)/") else { return }
        // The imdb:// scheme opens the app; without it installed, fall back to the website.
        openURL(app) { accepted in if !accepted { openURL(web) } }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Plays a trailer full screen.
struct TrailerPlayer: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding()
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel("\(title) trailer")
    }
}
