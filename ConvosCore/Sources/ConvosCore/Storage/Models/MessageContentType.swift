import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite, assistantJoinRequest

    var marksConversationAsUnread: Bool {
        switch self {
        case .update, .assistantJoinRequest:
            false
        default:
            true
        }
    }
}
