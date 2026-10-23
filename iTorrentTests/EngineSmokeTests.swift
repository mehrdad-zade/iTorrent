import Foundation
import Testing
import LibTorrent
@testable import iTorrent

/// Live network test: downloads the start of the official Ubuntu Server ISO and checks that
/// no file data is uploaded. Opt-in because it needs internet access and a healthy swarm:
/// `RUN_NETWORK_TESTS=1` in the scheme or `TEST_RUNNER_RUN_NETWORK_TESTS=1 xcodebuild test`.
@MainActor
struct EngineSmokeTests {
    static let ubuntuHash = "A1DFEFEC1A9DD7FA8A041EBEEEA271DB55126D2F"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"),
          .timeLimit(.minutes(5)))
    func downloadsWithoutUploading() async throws {
        let magnet = URL(string: "magnet:?xt=urn:btih:\(Self.ubuntuHash)&dn=ubuntu-24.04.3-live-server-amd64.iso&tr=https%3A%2F%2Ftorrent.ubuntu.com%2Fannounce")!
        let session = TorrentEngine.session
        let handle = try #require(session.torrents.first { $0.hexHash == Self.ubuntuHash }
                                  ?? session.addTorrent(MagnetURI(unsafeWithMagnetURI: magnet)))
        handle.resume()
        defer { session.removeTorrent(handle, deleteFiles: true) }

        var snapshot = handle.snapshot
        for _ in 0..<240 {
            try await Task.sleep(for: .seconds(1))
            handle.updateSnapshot()
            snapshot = handle.snapshot
            if snapshot.totalDone > 20_000_000 { break }
        }
        print("ENGINE downloaded=\(snapshot.totalDone) uploadedPayload=\(snapshot.totalPayloadUpload) uploadedTotal=\(snapshot.totalUpload) peers=\(snapshot.numberOfPeers)")
        #expect(snapshot.totalDone > 20_000_000)
        // Leech-only: peers are never unchoked, so no piece data is uploaded.
        #expect(snapshot.totalPayloadUpload == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1"),
          .timeLimit(.minutes(5)))
    func managerStartsStopsAndResumes() async throws {
        let result = SearchResult(
            infoHash: Self.ubuntuHash, name: "ubuntu-24.04.3-live-server-amd64.iso", type: "Applications > UNIX",
            size: "3 GiB", uploader: "ubuntu",
            magnet: URL(string: "magnet:?xt=urn:btih:\(Self.ubuntuHash)&tr=https%3A%2F%2Ftorrent.ubuntu.com%2Fannounce")!,
            sourceName: "test")
        let downloads = DownloadManager.shared
        downloads.start(result)
        #expect(downloads.items[Self.ubuntuHash]?.state.isActive == true)

        for _ in 0..<120 where (downloads.items[Self.ubuntuHash]?.progress ?? 0) < 0.002 {
            try await Task.sleep(for: .seconds(1))
        }
        let item = try #require(downloads.items[Self.ubuntuHash])
        print("ENGINE manager state=\(item.state) progress=\(item.progress) rate=\(item.downloadRate)")
        #expect(item.state == .downloading)
        #expect(item.progress > 0)

        downloads.stop(Self.ubuntuHash)
        try await Task.sleep(for: .seconds(2))
        #expect(downloads.items[Self.ubuntuHash]?.state == .stopped)

        downloads.resume(Self.ubuntuHash)
        try await Task.sleep(for: .seconds(2))
        #expect(downloads.items[Self.ubuntuHash]?.state.isActive == true)

        downloads.stop(Self.ubuntuHash)
        if let handle = TorrentEngine.session.torrents.first(where: { $0.hexHash == Self.ubuntuHash }) {
            TorrentEngine.session.removeTorrent(handle, deleteFiles: true)
        }
    }
}
