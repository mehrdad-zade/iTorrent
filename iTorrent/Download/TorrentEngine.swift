import Foundation
import LibTorrent

/// Owns the single libtorrent session, configured for download-only use.
enum TorrentEngine {
    /// Files land directly in the app's folder in Files (On My iPhone › iTorrent).
    static let downloadsURL = URL.documentsDirectory
    private static let stateURL = URL.applicationSupportDirectory.appending(path: "Torrents", directoryHint: .isDirectory)

    static let session: Session = {
        migrateLegacyDownloadsFolder()
        let torrentsURL = stateURL.appending(path: "Metadata", directoryHint: .isDirectory)
        let fastResumeURL = stateURL.appending(path: "FastResume", directoryHint: .isDirectory)
        for url in [downloadsURL, torrentsURL, fastResumeURL] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // libtorrent restores saved torrents, magnets and resume data inside this initializer.
        return Session(downloadsURL, torrentsPath: torrentsURL, fastResumePath: fastResumeURL,
                       settings: leechOnlySettings, storages: DownloadLocation.storages())
    }()

    /// Earlier builds saved into Documents/Downloads. Move those files up before the session starts:
    /// libtorrent restores unfinished torrents into `downloadsURL`, so they resume where they left off.
    private static func migrateLegacyDownloadsFolder() {
        let fm = FileManager.default
        let legacy = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        guard let entries = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let target = downloadsURL.appending(path: entry.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: entry, to: target) }
        }
        if (try? fm.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true { try? fm.removeItem(at: legacy) }
    }

    private static var leechOnlySettings: Session.Settings {
        let settings = Session.Settings()
        settings.agentName = "iTorrent"
        settings.preallocateStorage = false

        // No queue limits (-1): a queued torrent looks paused, and pauses the user didn't ask for trigger a notification.
        settings.maxActiveTorrents = -1
        settings.maxDownloadingTorrents = -1
        // No seeding: auto-managed torrents that finish are never given a seed slot.
        settings.maxUploadingTorrents = 0

        // No file data leaves the device: peers are never unchoked, so they can't request pieces
        // (added to LibTorrent-Swift by patches/LibTorrent-Swift-leech-only-setting.patch).
        // The rate limit can't be used for this: it also throttles our own piece requests.
        settings.leechOnly = true
        settings.maxDownloadSpeed = 0 // unlimited
        settings.maxUploadSpeed = 64 * 1024 // only protocol traffic (requests, handshakes) is sent

        settings.isDhtEnabled = true // needed to resolve magnet links
        settings.isLsdEnabled = false
        settings.isUtpEnabled = true
        // Don't open router ports, so peers can't connect in to request pieces.
        settings.isUpnpEnabled = false
        settings.isNatEnabled = false

        settings.encryptionPolicy = .enabled
        settings.validateHttpsTrackers = true
        settings.port = 6881
        settings.portBindRetries = 10
        settings.listenInterfaces = "0.0.0.0:6881,[::]:6881"
        settings.outgoingInterfaces = ""
        settings.proxyType = .none
        settings.proxyHostname = ""
        settings.proxyUsername = ""
        settings.proxyPassword = ""
        return settings
    }
}

extension TorrentHandle {
    /// Uppercase hex v1 hash, matching `SearchResult.infoHash`.
    var hexHash: String {
        (infoHashes.hasV1 ? infoHashes.v1 : infoHashes.best).hex.uppercased()
    }
}
