# iTorrent

SwiftUI iPhone app (iOS 26+) that searches torrent indexes and downloads with libtorrent, without uploading any file data.

## Build

```sh
brew install cmake boost
git submodule update --init --recursive
./scripts/build-libtorrent.sh      # generates the libtorrent Xcode project, applies patches/
open iTorrent.xcworkspace          # scheme: iTorrent
```

Use the **workspace**, not the project: it builds `Submodules/LibTorrent-Swift` (and libtorrent) as implicit dependencies. Personal/sideload distribution: set your team under Signing & Capabilities.

## How it works

| Piece | File |
|---|---|
| Search sources, queried in order | `iTorrent/Search/PirateBayHTMLSource.swift` (thepiratebay0.org HTML), `ApiBaySource.swift` (thepiratebay.org's JSON API, apibay.org) |
| 10-per-page pagination: source 1 until it runs out, then source 2 | `iTorrent/Search/SearchPager.swift` |
| libtorrent session, leech-only settings | `iTorrent/Download/TorrentEngine.swift` |
| Download state, start/stop/resume, remove-on-complete | `iTorrent/Download/DownloadManager.swift` |
| Background execution | `iTorrent/Download/BackgroundKeeper.swift` |
| Configurable search sources (Settings, top = priority) | `iTorrent/Search/SourceStore.swift`, `iTorrent/UI/SettingsView.swift` |
| Header for video searches: the title (picked with IMDb's suggestions and the result names), Rotten Tomatoes Tomatometer and Popcornmeter, Open in IMDb | `iTorrent/Ratings/TitleLookup.swift`, `RottenTomatoes.swift`, `iTorrent/UI/TitleHeader.swift` |
| Delete a download's files (swipe or long-press in Downloads or on a result) | `DownloadManager.delete(_:)`, `iTorrent/UI/DownloadsView.swift` |
| First-launch permissions (Files, notifications, network, background) | `iTorrent/UI/PermissionsView.swift` |
| Notifications: complete, failed, or paused by the system (silent for manual stops) | `iTorrent/Support/Notifier.swift` |
| Custom download folder (security-scoped bookmark) | `iTorrent/Download/DownloadLocation.swift` |

Files are saved directly to `Documents`, visible in **Files → On My iPhone → iTorrent**. Files from older builds' `Downloads` subfolder are moved up on launch.

### No uploading

- `Session.Settings.leechOnly` (added by `patches/LibTorrent-Swift-leech-only-setting.patch`) sets libtorrent's unchoke and optimistic-unchoke slots to 0 and the allowed-fast set to 0. Peers are never allowed to request pieces.
- `active_seeds = 0`, and finished torrents are removed from the session right away (files are kept), so nothing ever seeds.
- Only protocol traffic is sent, such as handshakes and piece requests. The live test checks that `totalPayloadUpload == 0`.

### Background

1. Each download submits a `BGContinuedProcessingTask` (iOS 26). It shows system progress UI. If it's cancelled there or expires, the download stops.
2. **Aggressive background mode** (Settings, on by default) plays silence while downloads are active, so iOS doesn't suspend the app. App Store review rejects this, but it's fine for sideloading.
3. A force-quit app can't run on iOS. libtorrent's resume data restarts unfinished downloads on the next launch.

## Patches to LibTorrent-Swift

`scripts/build-libtorrent.sh` applies `patches/*.patch` to the submodule:

- **match-libtorrent-defines**: the wrapper compiled libtorrent headers with `TORRENT_ABI_VERSION=4` and without the library's public defines. That gave a struct-layout mismatch that corrupted memory in `addTorrent` (magnets failed with "missing info-hash", then crashed). The script also strips CMake's Debug-only `TORRENT_USE_ASSERTS` for the same reason.
- **leech-only-setting**: adds `leechOnly` and `totalPayloadUpload`.

## Tests

```sh
xcodebuild -workspace iTorrent.xcworkspace -scheme iTorrent -destination 'platform=iOS Simulator,name=iPhone 17' test
# Plus live tests (real sites + Ubuntu ISO swarm):
TEST_RUNNER_RUN_NETWORK_TESTS=1 xcodebuild ... test
```
