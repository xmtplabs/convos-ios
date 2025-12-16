import Foundation

struct NotificationConstants {
    // Storage keys
    struct StorageKeys {
        static let deviceToken: String = "push_notification_device_token"
        static let lastRegistrationDate: String = "push_notification_last_registration"
        static let subscribedTopics: String = "push_notification_subscribed_topics"
        static let conversationMessagesPrefix: String = "conversation_messages_"
        static let userProfiles: String = "user_profiles_cache"
    }

    // XMTP-specific constants
    struct XMTP {
        static let maxRetries: Int = 3
        static let retryDelay: TimeInterval = 1.0
    }

    // App-level in-process notifications
    struct AppNotifications {
        static let pushTokenDidChange: String = "convosPushTokenDidChange"
        static let explosionNotificationTapped: String = "explosionNotificationTapped"
        static let conversationNotificationTapped: String = "conversationNotificationTapped"
        static let conversationExpired: String = "conversationExpired"
    }
}

extension Notification.Name {
    public static let convosPushTokenDidChange: Notification.Name = Notification.Name(NotificationConstants.AppNotifications.pushTokenDidChange)
    public static let explosionNotificationTapped: Notification.Name = Notification.Name(NotificationConstants.AppNotifications.explosionNotificationTapped)
    public static let conversationNotificationTapped: Notification.Name = Notification.Name(NotificationConstants.AppNotifications.conversationNotificationTapped)
    public static let conversationExpired: Notification.Name = Notification.Name(NotificationConstants.AppNotifications.conversationExpired)
}
