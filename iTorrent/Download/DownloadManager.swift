import Foundation
import LibTorrent
import Observation

@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    enum State: String, Codable {
        case fetchingMetadata, downloading, stopped, finished, failed

        var isActive: Bool { self == .fetchingMetadata || self == .downloading }
    }

    struct Item: Identifiable, Codable {
        let infoHash: String
        var name: String
        var state: State
        var progress: Double = 0
        var downloadRate: UInt64 = 0
        var peers: Int = 0
        var error: String?
        /// Top-level file or folder libtorrent writes (the torrent's own name), once metadata is known.
        var contentName: String?
        /// Custom storage the files were saved to; nil means the app's own folder.
        var storageID: UUID?

        var id: String { infoHash }
    }

    /// Every download this app knows about, keyed by uppercase hex info hash.
    private(set) var items: [String: Item] = [:]

    @ObservationIgnored private let session = TorrentEngine.session
    @ObservationIgnored private var handles: [String: TorrentHandle] = [:]
    @ObservationIgnored private let finishedKey = "finishedDownloads"
    /// Pauses we caused (the user pressed Stop, or we already notified), so they don't trigger a notification.
    @ObservationIgnored private var expectedPauses: Set<String> = []
    /// When the user last started or resumed each download; libtorrent applies that asynchronously.
    @ObservationIgnored private var resumedAt: [String: Date] = [:]

    var sortedItems: [Item] { items.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    private init() {
        loadFinished()
        // Torrents restored by libtorrent from the previous run resume automatically
        // unless the user stopped them, since that paused state is in their resume data.
        for handle in session.torrents {
            handles[handle.hexHash] = handle
        }
        refresh()

        // The continued-processing task ended (iOS reclaimed background time, or it was cancelled
        // from the system progress UI). The download can't keep running, so pause and tell the user.
        BackgroundKeeper.shared.onExpired = { [weak self] hash in
            guard let self, let item = self.items[hash], item.state.isActive else { return }
            self.stop(hash)
            Notifier.downloadPaused(item.name, hash: hash, reason: "iOS ended its background time.")
        }

        // Poll once a second rather than on every libtorrent alert (one fires per downloaded piece).
        Task { [weak self] in
            var tick = 0
            while let self {
                self.refresh()
                // Files can be deleted in the Files app at any time; check every few seconds.
                if tick % 5 == 0 { self.forgetDeletedDownloads() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - User actions

    func start(_ result: SearchResult) {
        if let handle = handles[result.infoHash] {
            handle.resume()
        } else {
            let magnet = MagnetURI(unsafeWithMagnetURI: result.magnet)
            guard let handle = session.addTorrent(magnet, to: DownloadLocation.activeStorageID) else {
                items[result.infoHash] = Item(infoHash: result.infoHash, name: result.name, state: .failed,
                                              error: "Could not add torrent")
                return
            }
            handles[result.infoHash] = handle
            handle.resume()
        }
        items[result.infoHash, default: Item(infoHash: result.infoHash, name: result.name, state: .fetchingMetadata)]
            .state = .fetchingMetadata
        items[result.infoHash]?.error = nil
        expectedPauses.remove(result.infoHash)
        resumedAt[result.infoHash] = .now
        BackgroundKeeper.shared.begin(hash: result.infoHash, title: result.name)
        refresh()
    }

    func stop(_ hash: String) {
        expectedPauses.insert(hash)
        handles[hash]?.pause() // libtorrent saves resume data, so a later resume picks up where it left off
        items[hash]?.state = .stopped
        items[hash]?.downloadRate = 0
        BackgroundKeeper.shared.end(hash: hash, success: false)
        updateKeepAlive()
    }

    func resume(_ hash: String) {
        guard let handle = handles[hash], let item = items[hash] else { return }
        handle.resume()
        expectedPauses.remove(hash)
        resumedAt[hash] = .now
        items[hash]?.state = .downloading
        BackgroundKeeper.shared.begin(hash: hash, title: item.name)
    }

    /// Stops the download if needed and deletes its files from Files.
    func delete(_ hash: String) {
        guard let item = items[hash] else { return }
        expectedPauses.insert(hash)
        BackgroundKeeper.shared.end(hash: hash, success: false)
        if let handle = handles.removeValue(forKey: hash) {
            // libtorrent deletes exactly the files it created, including partially downloaded ones.
            session.removeTorrent(handle, deleteFiles: true)
        } else if let url = contentURL(of: item) {
            // Finished downloads were already removed from the session, so delete them directly.
            try? FileManager.default.removeItem(at: url)
        }
        items[hash] = nil
        resumedAt[hash] = nil
        saveFinished()
        updateKeepAlive()
    }

    /// Drops downloads whose files were deleted outside the app (for example in the Files app), so
    /// they leave the Downloads list. Running downloads are left alone: libtorrent writes their files.
    func forgetDeletedDownloads() {
        var changed = false
        for item in items.values where contentURL(of: item) == nil {
            let hasFiles = item.state == .finished || (item.state == .stopped && item.progress > 0)
            guard hasFiles else { continue }
            if let handle = handles.removeValue(forKey: item.infoHash) {
                session.removeTorrent(handle, deleteFiles: false)
            }
            items[item.infoHash] = nil
            changed = true
        }
        if changed { saveFinished() }
    }

    /// Opens Files at a download: the folder itself, or the folder holding a single file.
    func filesAppURL(of item: Item) -> URL? {
        guard let url = contentURL(of: item) else { return nil }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let target = isFolder ? url : url.deletingLastPathComponent()
        return URL(string: "shareddocuments://" + target.path(percentEncoded: true))
    }

    /// Where a download's files are, if they're still on disk.
    func contentURL(of item: Item) -> URL? {
        // Finished items saved by earlier builds have no contentName; their name came from the torrent.
        guard let name = item.contentName ?? (item.state == .finished ? item.name : nil),
              !name.isEmpty, let folder = DownloadLocation.folder(for: item.storageID) else { return nil }
        let url = folder.appending(path: name).standardizedFileURL
        // Never step outside the download folder or delete the folder itself, whatever the torrent is named.
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard url.path(percentEncoded: false).hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    // MARK: - Status

    private func refresh() {
        for (hash, handle) in handles {
            handle.updateSnapshot()
            let snapshot = handle.snapshot
            let previous = items[hash]?.state
            var item = items[hash] ?? Item(infoHash: hash, name: snapshot.name, state: .downloading)
            if snapshot.hasMetadata, !snapshot.name.isEmpty {
                item.name = snapshot.name
                item.contentName = snapshot.name
            }
            item.storageID = handle.storageUUID
            item.progress = snapshot.hasMetadata ? snapshot.progress : 0
            item.downloadRate = snapshot.downloadRate
            item.peers = Int(snapshot.numberOfPeers)

            // Before metadata arrives libtorrent reports 0 of 0 wanted bytes as "finished".
            let isComplete = snapshot.hasMetadata && snapshot.totalWanted > 0
                && (snapshot.isFinished || snapshot.isSeed || snapshot.state == .finished || snapshot.state == .seeding)

            switch snapshot.state {
            case _ where isComplete:
                item.progress = 1
                item.state = .finished
            case .storageError:
                item.state = .failed
                item.error = "Storage error"
            case .paused:
                item.state = .stopped
            case .downloadingMetadata:
                item.state = snapshot.isPaused ? .stopped : .fetchingMetadata
            default:
                item.state = snapshot.isPaused ? .stopped : .downloading
            }
            // Until libtorrent catches up with a tap, show what the user asked for.
            if expectedPauses.contains(hash), item.state.isActive {
                item.state = .stopped
            } else if item.state == .stopped, let previous, previous.isActive,
                      Date.now.timeIntervalSince(resumedAt[hash] ?? .distantPast) < 3 {
                item.state = previous
            }
            items[hash] = item
            notifyIfInterrupted(item, previous: previous)

            if item.state == .finished {
                finish(hash)
            } else if item.state.isActive {
                BackgroundKeeper.shared.update(hash: hash, progress: item.progress, rate: item.downloadRate)
            }
        }
        updateKeepAlive()
    }

    /// Removes a completed torrent from the session right away (files are kept) so it never seeds.
    private func finish(_ hash: String) {
        guard let handle = handles.removeValue(forKey: hash) else { return }
        session.removeTorrent(handle, deleteFiles: false)
        items[hash]?.downloadRate = 0
        BackgroundKeeper.shared.end(hash: hash, success: true)
        saveFinished()
        if let item = items[hash] {
            Notifier.downloadCompleted(item.name, hash: hash, location: DownloadLocation.displayName)
        }
    }

    /// Notifies when a download stops without the user asking: libtorrent paused it (for example after
    /// a disk error) or it failed. Manual stops are in `expectedPauses` and stay silent.
    private func notifyIfInterrupted(_ item: Item, previous: State?) {
        guard let previous, previous != item.state else { return }
        switch item.state {
        case .stopped where previous.isActive && !expectedPauses.contains(item.infoHash):
            BackgroundKeeper.shared.end(hash: item.infoHash, success: false)
            Notifier.downloadPaused(item.name, hash: item.infoHash, reason: "the download was paused.")
        case .failed:
            BackgroundKeeper.shared.end(hash: item.infoHash, success: false)
            Notifier.downloadFailed(item.name, hash: item.infoHash, reason: item.error ?? "an error occurred.")
        default:
            break
        }
    }

    private func updateKeepAlive() {
        BackgroundKeeper.shared.setKeepAlive(items.values.contains { $0.state.isActive })
    }

    // MARK: - Persistence of completed items (libtorrent forgets them once removed)

    private func loadFinished() {
        guard let data = UserDefaults.standard.data(forKey: finishedKey),
              let finished = try? JSONDecoder().decode([Item].self, from: data) else { return }
        for item in finished { items[item.infoHash] = item }
    }

    private func saveFinished() {
        let finished = items.values.filter { $0.state == .finished }
        UserDefaults.standard.set(try? JSONEncoder().encode(finished), forKey: finishedKey)
    }
}
