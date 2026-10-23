import Foundation

/// Serves results in fixed-size pages, draining sources strictly in order:
/// source 1 supplies every page until it runs out, then source 2 continues.
final class SearchPager {
    static let pageSize = 10

    let query: String
    private let sources: [any TorrentSource]
    private var sourceIndex = 0
    private var nextPage = 1
    private var buffer: [SearchResult] = []
    private var seenHashes: Set<String> = []
    private(set) var errors: [String] = []

    init(query: String, sources: [any TorrentSource]) {
        self.query = query
        self.sources = sources
    }

    var hasMore: Bool { !buffer.isEmpty || sourceIndex < sources.count }

    func loadNext() async throws -> [SearchResult] {
        while buffer.count < Self.pageSize, sourceIndex < sources.count {
            let source = sources[sourceIndex]
            do {
                let page = try await source.fetchPage(query: query, page: nextPage)
                buffer += page.results.filter { seenHashes.insert($0.infoHash).inserted }
                if page.hasMore {
                    nextPage += 1
                } else {
                    advanceSource()
                }
            } catch {
                try Task.checkCancellation()
                errors.append("\(source.name): \(error.localizedDescription)")
                advanceSource()
            }
        }
        try Task.checkCancellation()
        let page = Array(buffer.prefix(Self.pageSize))
        buffer.removeFirst(page.count)
        return page
    }

    private func advanceSource() {
        sourceIndex += 1
        nextPage = 1
    }
}
