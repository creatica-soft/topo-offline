import Foundation
import UserNotifications

/// The app's two notifications: the off-route warning while following, and the reminder to
/// pause a recording that looks stopped. Both are made on the phone: nothing is sent anywhere,
/// and they work without signal.
@MainActor
final class Notifications: NSObject {
    static let shared = Notifications()

    nonisolated static let offRoute = "off-route"
    nonisolated static let stopReminder = "stop-reminder"
    nonisolated private static let recordingCategory = "recording"
    nonisolated private static let pauseAction = "pause"

    /// Called when Pause is tapped on the reminder (the phone can stay locked).
    var onPause: (() -> Void)?

    /// At launch: handles taps on the Pause button, and how notifications show in the app.
    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let pause = UNNotificationAction(identifier: Self.pauseAction, title: "Pause recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.recordingCategory, actions: [pause], intentIdentifiers: []),
        ])
    }

    /// Asks once (when following or recording starts). If notifications are turned off, the
    /// off-route warning is a vibration in the app only, and there's no reminder to pause.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ id: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if id == Self.stopReminder { content.categoryIdentifier = Self.recordingCategory }
        // A delayed one is delivered by iOS even if the app is asleep (a still phone gets no GPS
        // updates to wake it). Posting the same id again replaces it, restarting the delay.
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Removes it, whether shown or still waiting.
    func remove(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    /// With the app on screen: the off-route banner at the top of the map already says it, so just
    /// the sound; the pause reminder shows as a banner too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier == Self.offRoute ? [.sound] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.pauseAction else { return }
        await MainActor.run { Notifications.shared.onPause?() }
    }
}
