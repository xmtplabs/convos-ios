import ConvosCore
import UIKit
import UserNotifications

// MARK: - App Delegate

/// Lightweight delegate for push notifications and scene configuration
@MainActor
class ConvosAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: (any SessionManagerProtocol)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SentryConfiguration.configure()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()

        Log.info("Received device token from APNS")
        // Store token in shared storage
        PushNotificationRegistrar.save(token: token)
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
        return []
    }

    // Handle notification taps
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        Log.debug("Notification tapped")

        // Check if this is an explosion notification
        if let notificationType = userInfo["notificationType"] as? String,
           notificationType == "explosion",
           let inboxId = userInfo["inboxId"] as? String,
           let conversationId = userInfo["conversationId"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .explosionNotificationTapped,
                    object: nil,
                    userInfo: [
                        "inboxId": inboxId,
                        "conversationId": conversationId,
                        "notificationType": notificationType
                    ]
                )
            }
            return
        }

        // Handle regular conversation notifications (Protocol messages)
        // v2 notifications use clientId, need to look up inboxId from database
        let conversationId = response.notification.request.content.threadIdentifier

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
