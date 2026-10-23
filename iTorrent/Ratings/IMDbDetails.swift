import Foundation

/// IMDb rating, credits, plot and trailer for one title.
nonisolated struct IMDbDetails: Hashable, Sendable {
    let id: String
    let rating: Double?
    let voteCount: Int?
    let plot: String?
    /// Directors for movies, creators for series.
    let directors: [String]
    let stars: [String]
    let genres: [String]
    let runtimeMinutes: Int?
    let isTV: Bool
    let posterURL: URL?
    /// HLS stream of the title's main trailer. The URL is signed and expires after a while.
    let trailerURL: URL?
}

/// Reads title details from IMDb's GraphQL endpoint, the one imdb.com itself uses. It needs no key;
/// IMDb's terms allow limited personal, non-commercial use.
actor IMDbService {
    static let shared = IMDbService()

    private let endpoint = URL(string: "https://caching.graphql.imdb.com/")!
    private var cache: [String: Task<IMDbDetails?, Never>] = [:]

    func details(for id: String) async -> IMDbDetails? {
        if let task = cache[id] { return await task.value }
        let task = Task { try? await self.fetch(id) }
        cache[id] = task
        return await task.value
    }

    private static let query = """
    query Title($id: ID!) { title(id: $id) {
      id titleType { canHaveEpisodes }
      ratingsSummary { aggregateRating voteCount }
      plot { plotText { plainText } }
      genres { genres { text } }
      runtime { seconds }
      primaryImage { url }
      principalCredits { category { id } credits(limit: 4) { name { nameText { text } } } }
      primaryVideos(first: 1) { edges { node { playbackURLs { url videoMimeType } } } }
    } }
    """

    private struct Request: Encodable {
        struct Variables: Encodable { let id: String }
        let query: String
        let variables: Variables
    }

    private func fetch(_ id: String) async throws -> IMDbDetails? {
        let data = try await HTTP.post(endpoint, json: Request(query: Self.query, variables: .init(id: id)), headers: [
            "x-imdb-client-name": "imdb-web-next",
            "Origin": "https://www.imdb.com",
        ])
        return try Self.parse(data)
    }

    // MARK: - Response

    private struct Response: Decodable {
        struct Text: Decodable { let text: String }
        struct Title: Decodable {
            struct Kind: Decodable { let canHaveEpisodes: Bool? }
            struct Ratings: Decodable { let aggregateRating: Double?; let voteCount: Int? }
            struct Plot: Decodable { struct PlotText: Decodable { let plainText: String? }; let plotText: PlotText? }
            struct Genres: Decodable { let genres: [Text]? }
            struct Runtime: Decodable { let seconds: Int? }
            struct Image: Decodable { let url: String? }
            struct Credits: Decodable {
                struct Category: Decodable { let id: String }
                struct Credit: Decodable { struct Name: Decodable { let nameText: Text? }; let name: Name? }
                let category: Category?
                let credits: [Credit]?
            }
            struct Videos: Decodable {
                struct Edge: Decodable {
                    struct Node: Decodable {
                        struct Playback: Decodable { let url: String; let videoMimeType: String? }
                        let playbackURLs: [Playback]?
                    }
                    let node: Node?
                }
                let edges: [Edge]?
            }
            let id: String
            let titleType: Kind?
            let ratingsSummary: Ratings?
            let plot: Plot?
            let genres: Genres?
            let runtime: Runtime?
            let primaryImage: Image?
            let principalCredits: [Credits]?
            let primaryVideos: Videos?
        }
        struct Payload: Decodable { let title: Title? }
        let data: Payload?
    }

    static func parse(_ data: Data) throws -> IMDbDetails? {
        guard let title = try JSONDecoder().decode(Response.self, from: data).data?.title else { return nil }
        func names(_ category: String) -> [String] {
            title.principalCredits?.first { $0.category?.id == category }?.credits?
                .compactMap { $0.name?.nameText?.text } ?? []
        }
        let playback = title.primaryVideos?.edges?.first?.node?.playbackURLs ?? []
        let trailer = (playback.first { $0.videoMimeType == "M3U8" } ?? playback.first { $0.videoMimeType == "MP4" })
            .flatMap { URL(string: $0.url) }
        let directors = names("director")
        return IMDbDetails(
            id: title.id,
            rating: title.ratingsSummary?.aggregateRating,
            voteCount: title.ratingsSummary?.voteCount,
            plot: title.plot?.plotText?.plainText,
            directors: directors.isEmpty ? names("creator") : directors,
            stars: names("cast"),
            genres: title.genres?.genres?.map(\.text) ?? [],
            runtimeMinutes: title.runtime?.seconds.map { $0 / 60 },
            isTV: title.titleType?.canHaveEpisodes ?? false,
            posterURL: title.primaryImage?.url.flatMap {
                URL(string: $0.replacingOccurrences(of: "._V1_.", with: "._V1_QL75_UX300_."))
            },
            trailerURL: trailer
        )
    }
}
