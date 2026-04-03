import ConvosCore
import ConvosCoreiOS
import UIKit
import UserNotifications

// MARK: - App Delegate

/// Lightweight delegate for push notifications and scene configuration
@MainActor
class ConvosAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    var session: (any SessionManagerProtocol)?
    var pushNotificationRegistrar: (any PushNotificationRegistrarProtocol)?
    private var leftConversationObserver: Any?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SentryConfiguration.configure()
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        application.registerForRemoteNotifications()
        leftConversationObserver = NotificationCenter.default.addObserver(
            forName: .leftConversationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let conversationId = notification.userInfo?["conversationId"] as? String else { return }
            Task { await self?.clearDeliveredNotifications(for: conversationId) }
        }
        return true
    }

    private func registerNotificationCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationAction.replyIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )
        let markReadAction = UNNotificationAction(
            identifier: NotificationAction.markReadIdentifier,
            title: "Mark as Read",
            options: []
        )
        let messageCategory = UNNotificationCategory(
            identifier: NotificationAction.messageCategoryIdentifier,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
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

    // MARK: - Background URLSession

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task {
            await BackgroundUploadManager.shared.handleEventsForBackgroundURLSession(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Handle notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conversationId = notification.request.content.threadIdentifier

        // Wake the inbox for this conversation so it's ready when the user opens it
        if !conversationId.isEmpty, let session = session {
            await session.wakeInboxForNotification(conversationId: conversationId)
        }

        // Handle explosion notifications - trigger cleanup and show banner
        if notification.request.content.userInfo["isExplosion"] as? Bool == true {
            Log.info("App in foreground - explosion notification received, triggering cleanup")
            NotificationCenter.default.post(
                name: .conversationExpired,
                object: nil,
                userInfo: notification.request.content.userInfo
            )
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

    // Handle notification taps and actions
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let conversationId = response.notification.request.content.threadIdentifier

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
            Log.warning("Notification received but conversationId is empty")
            return
        }

        switch response.actionIdentifier {
        case NotificationAction.replyIdentifier:
            await handleNotificationReply(response: response, conversationId: conversationId)

        case NotificationAction.markReadIdentifier:
            await clearDeliveredNotifications(for: conversationId)

        default:
            await handleNotificationTap(conversationId: conversationId)
        }
    }

    private func handleNotificationReply(response: UNNotificationResponse, conversationId: String) async {
        guard let textResponse = response as? UNTextInputNotificationResponse else { return }
        let replyText = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyText.isEmpty else { return }

        Log.info("Sending notification reply to conversation \(conversationId)")
        do {
            try await session?.sendNotificationReply(text: replyText, conversationId: conversationId)
            await clearDeliveredNotifications(for: conversationId)
        } catch {
            Log.error("Failed to send notification reply: \(error)")
        }
    }

    private func handleNotificationTap(conversationId: String) async {
        guard let session = session,
              let inboxId = await session.inboxId(for: conversationId) else {
            Log.warning("Notification tapped but could not find inboxId for conversationId: \(conversationId)")
            return
        }

        await session.wakeInboxForNotification(conversationId: conversationId)
        await clearDeliveredNotifications(for: conversationId)

        Log.info("Handling conversation notification tap for inboxId: \(inboxId), conversationId: \(conversationId)")
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

    /// Clears all delivered notifications for a specific conversation from the notification center
    private func clearDeliveredNotifications(for conversationId: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let toRemove = delivered
            .filter { $0.request.content.threadIdentifier == conversationId }
            .map { $0.request.identifier }

        guard !toRemove.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: toRemove)
        Log.info("Cleared \(toRemove.count) notifications for conversation \(conversationId)")
    }
}
