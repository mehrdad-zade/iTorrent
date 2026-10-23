import SwiftUI

struct ResultRow: View {
    let result: SearchResult
    /// Called instead of downloading when the user hasn't allowed saving to Files yet.
    var needsConsent: () -> Void = {}

    @Environment(DownloadManager.self) private var downloads
    @AppStorage(Consent.filesKey) private var filesConsent = false
    @State private var pendingDelete: DownloadManager.Item?

    var body: some View {
        let item = downloads.items[result.infoHash]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(result.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label(result.size, systemImage: "internaldrive")
                        Label(result.uploader, systemImage: "person")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                DownloadButton(item: item) {
                    if filesConsent { downloads.start(result) } else { needsConsent() }
                }
            }
            if let item {
                DownloadProgress(item: item)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let item { DownloadMenuItems(item: item) { pendingDelete = item } }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let item {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
            }
        }
        .deleteDownloadConfirmation(item: $pendingDelete)
    }
}

/// Start / stop / resume control for one torrent.
struct DownloadButton: View {
    let item: DownloadManager.Item?
    let start: () -> Void
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch item?.state {
            case nil:
                Button("Download", systemImage: "arrow.down", action: start)
                    .buttonStyle(.glassProminent)
            case .fetchingMetadata, .downloading:
                Button("Stop", systemImage: "stop.fill") { downloads.stop(item!.infoHash) }
                    .buttonStyle(.glass)
                    .tint(.red)
            case .stopped:
                Button("Resume", systemImage: "play.fill") { downloads.resume(item!.infoHash) }
                    .buttonStyle(.glassProminent)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise", action: start)
                    .buttonStyle(.glass)
                    .tint(.orange)
            case .finished:
                Button("Open in Files", systemImage: "folder.fill") {
                    if let url = downloads.filesAppURL(of: item!) { openURL(url) }
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
            }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .sensoryFeedback(trigger: item?.state) { old, new in
            switch new {
            case .fetchingMetadata where old == nil || old == .failed: .impact(weight: .medium)
            case .downloading where old == .stopped: .impact(weight: .medium)
            case .stopped: .impact(weight: .light)
            case .finished: .success
            case .failed: .error
            default: nil
            }
        }
    }
}

/// The progress bar shown under a result while it downloads.
struct DownloadProgress: View {
    let item: DownloadManager.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: item.progress)
                .tint(item.state == .finished ? .green : item.state == .stopped ? .gray : .accentColor)
            Text(status)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let percent = item.progress.formatted(.percent.precision(.fractionLength(1)))
        switch item.state {
        case .fetchingMetadata: return "Fetching metadata… · \(item.peers) peers"
        case .downloading:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(item.downloadRate), countStyle: .binary)
            return "\(percent) · \(rate)/s · \(item.peers) peers"
        case .stopped: return "Stopped at \(percent)"
        case .finished: return "Saved to \(DownloadLocation.displayName)"
        case .failed: return item.error ?? "Failed"
        }
    }
}
