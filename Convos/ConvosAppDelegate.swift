import ConvosCore
import UIKit
import UserNotifications

// MARK: - App Delegate

/// Lightweight delegate for push notifications and scene configuration
@MainActor
class ConvosAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: (any SessionManagerProtocol)?
    var pushNotificationRegistrar: (any PushNotificationRegistrarProtocol)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SentryConfiguration.configure()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()

        Log.info("Received device token from APNS")
        // Store token in shared storage
        pushNotificationRegistrar?.save(token: token)
        Log.info("Stored device token in shared storage")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Failed to register for remote notifications: \(error)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Handle notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conversationId = notification.request.content.threadIdentifier

        // Always show explosion notifications (identified by isExplosion flag in userInfo)
        if notification.request.content.userInfo["isExplosion"] as? Bool == true {
            Log.info("App in foreground - showing explosion notification banner (always show)")
            return [.banner, .sound]
        }

        // Check if we should display regular notifications based on the active conversation
        if !conversationId.isEmpty,
           let session = session {
            let shouldDisplay = await session.shouldDisplayNotification(for: conversationId)
            if !shouldDisplay {
                return []
            }
        }

        // Show notification banner when app is in foreground
        // NSE processes all notifications regardless of app state
        Log.info("App in foreground - showing notification banner")
        return [.banner]
    }

    // Handle notification taps
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        Log.debug("Notification tapped")

        let conversationId = response.notification.request.content.threadIdentifier

        // Check if this is an explosion notification tap
        if response.notification.request.content.userInfo["isExplosion"] as? Bool == true {
            Log.info("Explosion notification tapped")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .explosionNotificationTapped,
                    object: nil,
                    userInfo: response.notification.request.content.userInfo
                )
            }
            return
        }

        guard !conversationId.isEmpty else {
            Log.warning("Notification tapped but conversationId is empty")
            return
        }

        guard let session = session,
              let inboxId = await session.inboxId(for: conversationId) else {
            Log
                .warning(
                    "Notification tapped but could not find inboxId for conversationId: \(conversationId)"
                )
            return
        }

        Log
            .info(
                "Handling conversation notification tap for inboxId: \(inboxId), conversationId: \(conversationId)"
            )
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .conversationNotificationTapped,
                object: nil,
                userInfo: [
                    "inboxId": inboxId,
                    "conversationId": conversationId
                ]
            )
        }
    }
}
