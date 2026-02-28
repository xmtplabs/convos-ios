import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite, mcpApp

    var marksConversationAsUnread: Bool {
        switch self {
        case .update:
            false
        default:
            true
        }
    }
}
