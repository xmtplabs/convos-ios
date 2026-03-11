import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite, linkPreview
    case assistantJoinRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum

    var marksConversationAsUnread: Bool {
        switch self {
        case .update, .assistantJoinRequest:
            false
        default:
            true
        }
    }
}
