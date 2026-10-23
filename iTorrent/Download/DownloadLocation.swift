import Foundation
import LibTorrent

/// Where downloads are saved: the app's own Files folder, or a folder the user picked in Files.
enum DownloadLocation {
    private static let bookmarkKey = "customDownloadFolderBookmark"
    /// Fixed ID so libtorrent's resume data keeps pointing at the custom folder across launches.
    static let customStorageID = UUID(uuidString: "5B2F7C3E-9A41-4D8E-B6E2-7C1D0F4A9E11")!

    /// Security-scoped access stays open for the whole process: libtorrent writes from its own threads.
    private static var accessedURL: URL?

    static var defaultDisplayName: String { "On My iPhone › iTorrent" }

    private static var cached: [UUID: StorageModel]?

    static var customFolderName: String? {
        storages()[customStorageID]?.name
    }

    static var displayName: String { customFolderName ?? defaultDisplayName }

    /// The storage passed to `addTorrent(_:to:)`, or nil for the default folder.
    static var activeStorageID: UUID? { customFolderName == nil ? nil : customStorageID }

    /// Resolves the saved bookmark into libtorrent storages (empty when using the default folder).
    static func storages() -> [UUID: StorageModel] {
        if let cached { return cached }
        let resolved = resolveStorages()
        cached = resolved
        return resolved
    }

    private static func resolveStorages() -> [UUID: StorageModel] {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return [:] }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return [:] }
        if accessedURL != url {
            guard url.startAccessingSecurityScopedResource() else { return [:] }
            accessedURL = url
        }
        let storage = StorageModel(uuid: customStorageID, name: url.lastPathComponent, pathBookmark: bookmark)
        storage.url = url
        storage.resolved = true
        storage.allowed = true
        return [customStorageID: storage]
    }

    /// Saves a folder chosen with the Files picker. The picker's URL is security-scoped.
    static func setCustomFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        cached = nil
        TorrentEngine.session.storages = storages()
    }

    /// The folder a download was saved to: the custom folder for `storageID`, otherwise the app's folder.
    static func folder(for storageID: UUID?) -> URL? {
        guard let storageID else { return TorrentEngine.downloadsURL }
        return storages()[storageID]?.url
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        cached = nil
        TorrentEngine.session.storages = [:]
    }
}
