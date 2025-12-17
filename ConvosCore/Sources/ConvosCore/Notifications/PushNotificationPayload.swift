import Foundation

/// Represents decoded notification content from NSE processing
public struct DecodedNotificationContent {
    public let title: String?
    public let body: String
    public let conversationId: String?
    public let isDroppedMessage: Bool
    public let userInfo: [AnyHashable: Any]

    init(title: String?, body: String, conversationId: String?, userInfo: [AnyHashable: Any]) {
        self.title = title
        self.body = body
        self.conversationId = conversationId
        self.isDroppedMessage = false
        self.userInfo = userInfo
    }

    init(isDroppedMessage: Bool, userInfo: [AnyHashable: Any]) {
        self.title = nil
        self.body = ""
        self.conversationId = nil
        self.isDroppedMessage = isDroppedMessage
        self.userInfo = userInfo
    }

    static var droppedMessage: DecodedNotificationContent {
        .init(isDroppedMessage: true, userInfo: [:])
    }
}

/// Represents the payload structure of a push notification
public final class PushNotificationPayload {
    public let clientId: String?
    public let notificationData: NotificationData?
    public let apiJWT: String?
    public let userInfo: [AnyHashable: Any]

    // Decoded content properties (mutable for NSE processing)
    public var decodedTitle: String?
    public var decodedBody: String?

    public init(userInfo: [AnyHashable: Any]) {
        self.userInfo = userInfo
        self.clientId = userInfo["clientId"] as? String
        self.notificationData = NotificationData(dictionary: userInfo["notificationData"] as? [String: Any])
        self.apiJWT = userInfo["apiJWT"] as? String
        self.decodedTitle = nil
        self.decodedBody = nil
    }
}

// MARK: - Notification Data

public struct NotificationData {
    public let protocolData: ProtocolNotificationData?

    public init(dictionary: [String: Any]?) {
        guard let dict = dictionary else {
            self.protocolData = nil
            return
        }

        self.protocolData = ProtocolNotificationData(dictionary: dict)
    }
}

// MARK: - Protocol Notification Data

public struct ProtocolNotificationData {
    public let contentTopic: String?
    public let encryptedMessage: String?
    public let messageType: String?

    public var conversationId: String? {
        guard let topic = contentTopic else { return nil }
        return topic.conversationIdFromXMTPGroupTopic
    }

    public init(dictionary: [String: Any]?) {
        guard let dict = dictionary else {
            self.contentTopic = nil
            self.encryptedMessage = nil
            self.messageType = nil
            return
        }

        self.contentTopic = dict["contentTopic"] as? String
        self.encryptedMessage = dict["encryptedMessage"] as? String
        self.messageType = dict["messageType"] as? String
    }
}

// MARK: - Convenience Extensions

public extension PushNotificationPayload {
    /// Creates a thread identifier for grouping notifications
    var threadIdentifier: String? {
        notificationData?.protocolData?.conversationId
    }

    /// Generates a display title for the notification
    var displayTitle: String? {
        nil // Use default title
    }

    /// Generates a display body for the notification
    var displayBody: String? {
        "New message"
    }

    /// Generates a display title for the notification with decoded content
    /// - Returns: The display title with decoded content if available
    func displayTitleWithDecodedContent() -> String? {
        // Use decoded title if available and non-empty, otherwise fall back to default
        guard let decodedTitle = decodedTitle else {
            return displayTitle
        }

        let trimmed = decodedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayTitle : trimmed
    }

    /// Generates a display body for the notification with decoded content
    /// - Returns: The display body with decoded content if available
    func displayBodyWithDecodedContent() -> String? {
        // Use decoded body if available and non-empty, otherwise fall back to default
        guard let decodedBody = decodedBody else {
            return displayBody
        }

        let trimmed = decodedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayBody : trimmed
    }

    /// Checks if the notification has valid data for processing
    /// v2 notifications must have a clientId
    var isValid: Bool {
        guard let id = clientId else { return false }
        return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
