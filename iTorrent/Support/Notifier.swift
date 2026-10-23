import Foundation
import UserNotifications

/// Local notifications for downloads that finish, fail, or are paused by something other than the user.
enum Notifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "downloads"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func downloadCompleted(_ name: String, hash: String, location: String) {
        post(title: "Download complete", body: "\(name) was saved to \(location).", id: "done-\(hash)")
    }

    static func downloadPaused(_ name: String, hash: String, reason: String) {
        post(title: "Download paused", body: "\(name): \(reason) Open iTorrent to resume.", id: "paused-\(hash)")
    }

    static func downloadFailed(_ name: String, hash: String, reason: String) {
        post(title: "Download stopped", body: "\(name): \(reason)", id: "failed-\(hash)")
    }
}

/// Shows notifications as banners while the app is open too.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
