import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

enum Consent {
    static let filesKey = "consentSaveToFiles"
    static let onboardingKey = "onboardingComplete"
}

/// Explains what iTorrent needs and asks for it. Shown on first launch and from Settings.
struct PermissionsView: View {
    var isOnboarding = false

    @AppStorage(Consent.filesKey) private var filesConsent = false
    @AppStorage(Consent.onboardingKey) private var onboardingComplete = false
    @AppStorage(BackgroundKeeper.silentAudioKey) private var silentAudio = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showFolderPicker = false
    @State private var folderName = DownloadLocation.customFolderName
    @State private var folderError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isOnboarding {
                        Text("iTorrent needs a few permissions before it can download for you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    filesCard
                    notificationsCard
                    networkCard
                    backgroundCard
                }
                .padding()
            }
            .navigationTitle(isOnboarding ? "Welcome" : "Permissions")
            .toolbar {
                if isOnboarding {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Continue") {
                            onboardingComplete = true
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!filesConsent)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .interactiveDismissDisabled(isOnboarding)
            .task { notificationStatus = await Notifier.authorizationStatus() }
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                do {
                    try DownloadLocation.setCustomFolder(try result.get())
                    folderName = DownloadLocation.customFolderName
                    folderError = nil
                    filesConsent = true
                } catch {
                    folderError = "Couldn't use that folder: \(error.localizedDescription)"
                }
            }
            .sensoryFeedback(.success, trigger: filesConsent) { _, granted in granted }
            .sensoryFeedback(.success, trigger: notificationStatus) { _, status in status == .authorized }
        }
    }

    private var filesCard: some View {
        PermissionCard(icon: "folder.fill", tint: .blue, title: "Save to Files",
                       detail: "Downloads are saved where you can open them in the Files app: \(folderName ?? DownloadLocation.defaultDisplayName).",
                       granted: filesConsent) {
            if !filesConsent {
                Button("Allow Saving to Files") { filesConsent = true }
                    .buttonStyle(.glassProminent)
            }
            HStack {
                Button(folderName == nil ? "Choose Another Folder…" : "Change Folder…") { showFolderPicker = true }
                    .buttonStyle(.glass)
                if folderName != nil {
                    Button("Use Default") {
                        DownloadLocation.resetToDefault()
                        folderName = nil
                    }
                    .buttonStyle(.glass)
                }
            }
            if let folderError {
                Text(folderError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var notificationsCard: some View {
        PermissionCard(icon: "bell.badge.fill", tint: .red, title: "Notifications",
                       detail: "Get told when a download finishes, or when it stops without you pausing it.",
                       granted: notificationStatus == .authorized || notificationStatus == .provisional) {
            switch notificationStatus {
            case .notDetermined:
                Button("Allow Notifications") {
                    Task {
                        _ = await Notifier.requestAuthorization()
                        notificationStatus = await Notifier.authorizationStatus()
                    }
                }
                .buttonStyle(.glassProminent)
            case .denied:
                Button("Turn On in Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
            default:
                EmptyView()
            }
        }
    }

    private var networkCard: some View {
        PermissionCard(icon: "network", tint: .green, title: "Network",
                       detail: "iTorrent connects to other peers to download. iOS may ask to let it find devices on your local network. Allowing that lets it reach peers on the same Wi-Fi.",
                       granted: nil) { EmptyView() }
    }

    private var backgroundCard: some View {
        PermissionCard(icon: "arrow.down.app.fill", tint: .purple, title: "Background Downloads",
                       detail: "Downloads show their progress on the Lock Screen. Aggressive mode also keeps iTorrent running in the background (it plays silence) so downloads aren't suspended.",
                       granted: nil) {
            Toggle("Aggressive background mode", isOn: $silentAudio)
                .onChange(of: silentAudio) { BackgroundKeeper.shared.applyKeepAlive() }
        }
    }
}

private struct PermissionCard<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    /// nil for informational cards with nothing to grant.
    let granted: Bool?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.gradient, in: .rect(cornerRadius: 9))
                Text(title).font(.headline)
                Spacer()
                if let granted {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(granted ? .green : .secondary)
                        .font(.title3)
                        .accessibilityLabel(granted ? "Allowed" : "Not allowed yet")
                }
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
