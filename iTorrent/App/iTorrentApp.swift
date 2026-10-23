import SwiftUI

@main
struct iTorrentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var downloads = DownloadManager.shared

    init() {
        NotificationPresenter.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            SearchView()
                .environment(downloads)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: BackgroundKeeper.shared.didEnterBackground()
            case .active:
                BackgroundKeeper.shared.willEnterForeground()
                downloads.forgetDeletedDownloads() // the user may have deleted files in the Files app
            default: break
            }
        }
    }
}
