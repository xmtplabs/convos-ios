import ConvosCore
import ConvosCoreiOS
import UIKit
import UserNotifications

// MARK: - App Delegate

/// Lightweight delegate for push notifications and scene configuration
@MainActor
class ConvosAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    var session: (any SessionManagerProtocol)?
    /// Republishes staged-but-unpublished outgoing messages; injected by
    /// ConvosApp so the delegate can run it when a share-extension upload
    /// wakes the app in the background.
    var shareExtensionOutboxDrain: (@Sendable () async -> Void)?
    private var leftConversationObserver: Any?
    private var foregroundObserver: Any?
    /// Reconstituted handle on the share extension's background upload
    /// session, created on first wake so pending events have a delegate.
    private var shareExtensionUploads: BackgroundUploadManager?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PostHogConfiguration.configure()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        leftConversationObserver = NotificationCenter.default.addObserver(
            forName: .leftConversationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let conversationId = notification.userInfo?["conversationId"] as? String else { return }
            Task { await self?.clearDeliveredNotifications(for: conversationId) }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            BadgeCounter.reset(appGroupIdentifier: ConfigManager.shared.currentEnvironment.appGroupIdentifier)
            UNUserNotificationCenter.current().setBadgeCount(0)
        }
        return true
    }

    // Lifecycle ordering invariant for the singleton-based token handoff:
    //
    //   ConvosApp.init
    //     |
    //     +--> PlatformProviders.iOS
    //     |       |
    //     |       +--> PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
    //     |                            (singleton _shared is set HERE)
    //     v
    //   UIKit lifecycle starts
    //     |
    //     +--> application(_:didFinishLaunchingWithOptions:)
    //     |       |
    //     |       +--> UIApplication.registerForRemoteNotifications()
    //     v
    //   APNS callback
    //     |
    //     +--> didRegisterForRemoteNotificationsWithDeviceToken
    //             |
    //             +--> PushNotificationRegistrar.save(token:)
    //                     |
    //                     +-- _shared != nil (normal lifecycle) -> save + post notification
    //                     +-- _shared == nil (test / extension)  -> Log.error + no-op (D10)
    //
    // The singleton is configured before UIKit fires didFinishLaunching, so the
    // happy path is race-free by construction. The graceful no-op covers UI tests
    // and any future lifecycle change without crashing the process.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()

        Log.info("Received device token from APNS")
        PushNotificationRegistrar.save(token: token)
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
        if identifier == BackgroundUploadManager.shareExtensionSessionIdentifier {
            handleShareExtensionUploadEvents(application, completionHandler: completionHandler)
            return
        }
        Task {
            await BackgroundUploadManager.shared.handleEventsForBackgroundURLSession(
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }

    /// A share-extension upload finished after the extension died; iOS
    /// launched us in the background to collect the session events. Adopt the
    /// extension's session so those events drain, then republish whatever the
    /// extension staged but never published, holding a background task
    /// assertion so the publish gets its ~30 seconds of runtime.
    private func handleShareExtensionUploadEvents(
        _ application: UIApplication,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        if shareExtensionUploads == nil {
            shareExtensionUploads = BackgroundUploadManager(
                sessionIdentifier: BackgroundUploadManager.shareExtensionSessionIdentifier,
                sharedContainerIdentifier: ConfigManager.shared.currentEnvironment.appGroupIdentifier
            )
        }
        guard let manager = shareExtensionUploads else { return }
        let drain = shareExtensionOutboxDrain
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = application.beginBackgroundTask(withName: "share-extension-outbox-drain") {
            application.endBackgroundTask(backgroundTask)
        }
        Task {
            await manager.handleEventsForBackgroundURLSession(
                identifier: BackgroundUploadManager.shareExtensionSessionIdentifier,
                completionHandler: completionHandler
            )
            await drain?()
            await MainActor.run {
                application.endBackgroundTask(backgroundTask)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conversationId = notification.request.content.threadIdentifier

        if !conversationId.isEmpty, let session = session {
            session.wakeInboxForNotification()
        }

        if notification.request.content.userInfo["isExplosion"] as? Bool == true {
            Log.info("App in foreground - explosion notification received, triggering cleanup")
            NotificationCenter.default.post(
                name: .conversationExpired,
                object: nil,
                userInfo: notification.request.content.userInfo
            )
            return [.banner, .sound]
        }

        if !conversationId.isEmpty,
           let session = session {
            let shouldDisplay = await session.shouldDisplayNotification(for: conversationId)
            if !shouldDisplay {
                return []
            }
        }

        Log.info("App in foreground - showing notification banner")
        return [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        Log.debug("Notification tapped")

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

        session.wakeInboxForNotification()
        await clearDeliveredNotifications(for: conversationId)

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
