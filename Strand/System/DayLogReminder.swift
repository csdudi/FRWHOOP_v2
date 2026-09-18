import Foundation
import UserNotifications

/// Evening reminder to fill the daily baseline log. Repeats at 21:00 local time.
enum DayLogReminder {
    static let notificationCategoryId = "baseline-day-log"
    private static let requestId = "baseline-day-log-evening"

    @MainActor
    static func activate() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    schedule(center)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted { schedule(center) }
                    }
                default:
                    break
                }
            }
        }
    }

    private static func schedule(_ center: UNUserNotificationCenter) {
        center.removePendingNotificationRequests(withIdentifiers: [requestId])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Daily log")
        content.body = String(localized: "A short daily log keeps your baseline honest — mood, load, and what the day was like.")
        content.sound = .default
        content.categoryIdentifier = notificationCategoryId

        var comps = DateComponents()
        comps.hour = 21
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}
