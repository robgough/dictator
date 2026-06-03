import Foundation
import UserNotifications

/// Posts a local notification when a meeting's notes are ready, so a user who
/// kicked off a recording and switched away gets told the result exists rather
/// than having to come back and check. Best-effort: authorization is requested
/// lazily the first time we'd actually post, and any failure is silent.
enum MeetingNotifier {
    static func notifyNotesReady(meetingTitle: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                post(title: meetingTitle, via: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(title: meetingTitle, via: center) }
                }
            default:
                break
            }
        }
    }

    private static func post(title: String, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting notes ready"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
