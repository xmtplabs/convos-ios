import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable {
    case text, emoji, attachments, update, invite

    var marksConversationAsUnread: Bool {
        switch self {
        case .update:
            false
        default:
            true
        }
    }
}
