import SwiftUI

/// Every download, so one can still be stopped or deleted after its search results are gone.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: DownloadManager.Item?

    var body: some View {
        NavigationStack {
            List(downloads.sortedItems) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        DownloadProgress(item: item)
                    }
                    DownloadButton(item: item) { downloads.resume(item.infoHash) }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
                }
                .contextMenu { DownloadMenuItems(item: item) { pendingDelete = item } }
            }
            .overlay {
                if downloads.items.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .deleteDownloadConfirmation(item: $pendingDelete)
            .onAppear { downloads.forgetDeletedDownloads() }
        }
    }
}

/// "Show in Files" and "Delete" for a download, used in context menus.
struct DownloadMenuItems: View {
    let item: DownloadManager.Item
    let delete: () -> Void
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let filesURL = downloads.filesAppURL(of: item) {
            Button("Show in Files", systemImage: "folder") { openURL(filesURL) }
        }
        Button("Delete Download", systemImage: "trash", role: .destructive, action: delete)
    }
}

extension View {
    /// Asks before deleting a download's files, then deletes them.
    func deleteDownloadConfirmation(item: Binding<DownloadManager.Item?>) -> some View {
        modifier(DeleteDownloadConfirmation(item: item))
    }
}

private struct DeleteDownloadConfirmation: ViewModifier {
    @Binding var item: DownloadManager.Item?
    @Environment(DownloadManager.self) private var downloads
    @State private var deleted = 0

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete “\(item?.name ?? "")”?", isPresented: Binding(
                get: { item != nil }, set: { if !$0 { item = nil } }
            ), titleVisibility: .visible, presenting: item) { item in
                Button("Delete Files", role: .destructive) {
                    downloads.delete(item.infoHash)
                    deleted += 1
                }
            } message: { item in
                Text(item.state.isActive || item.state == .stopped
                     ? "The download stops and everything downloaded so far is removed from Files."
                     : "The downloaded files are removed from Files. This can't be undone.")
            }
            .sensoryFeedback(.success, trigger: deleted)
    }
}
