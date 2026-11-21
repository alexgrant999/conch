import AppKit
import UserNotifications

/// macOS notifications and the dock badge.
/// UNUserNotificationCenter crashes in a process without a bundle identifier (`swift run`), so every call is a
/// no-op unless Bundle.main.bundleIdentifier is set.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    /// Called with the session id when the user clicks a notification. The app delegate wires this to
    /// SessionStore.select and activates the app.
    var onActivateSession: ((UUID) -> Void)?

    private var lastBadgeLabel: String?

    // A bare binary can carry an embedded Info.plist (so it has a bundle id) and still crash
    // UNUserNotificationCenter, which needs a real .app bundle. Check both.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        guard isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self { center.delegate = self }
        return center
    }

    func requestAuthorizationIfNeeded() {
        // @Sendable keeps these completion handlers nonisolated: UserNotifications calls them on a background queue.
        center?.requestAuthorization(options: [.alert, .sound]) { @Sendable _, error in
            if let error { NSLog("Conch: notification authorization failed: %@", error.localizedDescription) }
        }
    }

    /// Posts one notification. Replaces any earlier notification for the same session.
    func post(title: String, body: String, sessionID: UUID) {
        guard let center else { return }
        let identifier = sessionID.uuidString
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = identifier
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { @Sendable error in
            if let error { NSLog("Conch: could not post notification: %@", error.localizedDescription) }
        }
    }

    /// Removes delivered notifications for the session (called when it is seen).
    func clear(sessionID: UUID) {
        guard let center else { return }
        let identifier = sessionID.uuidString
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Empty string when count is 0.
    func updateDockBadge(count: Int) {
        guard isAvailable else { return }
        let label = count > 0 ? String(count) : ""
        guard label != lastBadgeLabel else { return }
        lastBadgeLabel = label
        NSApplication.shared.dockTile.badgeLabel = label
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? UUID(uuidString: response.notification.request.identifier)
            : nil
        if let sessionID {
            Task { @MainActor in
                self.onActivateSession?(sessionID)
            }
        }
        completionHandler()
    }
}
