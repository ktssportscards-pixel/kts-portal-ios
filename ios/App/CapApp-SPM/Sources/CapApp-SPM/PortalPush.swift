import UIKit
import UserNotifications

// Push notifications. Every logged-in user registers (AppState.maybeRegisterPush): admins
// get "new submission" alerts, and all users can receive broadcast announcements. The AppDelegate
// (App target) receives the APNs device token and hands it to API.registerPushToken; a tapped
// push with screen:"review" posts .ktsOpenReview, which AppState observes to deep-link to Review Cards.

public extension Notification.Name {
    static let ktsOpenReview = Notification.Name("kts.push.openReview")
}

public enum KTSPush {
    // Ask for notification permission once, and on grant register for remote (APNs) notifications.
    public static func requestAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
