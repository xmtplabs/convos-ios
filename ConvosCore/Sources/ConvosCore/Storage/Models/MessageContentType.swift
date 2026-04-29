import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite
    case linkPreview // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case assistantJoinRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionGrantRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case capabilityRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case capabilityRequestResult // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionEvent // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionInvocation // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionInvocationResult // swiftlint:disable:this raw_value_for_camel_cased_codable_enum

    var marksConversationAsUnread: Bool {
        switch self {
        case .update,
             .assistantJoinRequest,
             .connectionGrantRequest,
             .capabilityRequest,
             .capabilityRequestResult,
             .connectionEvent,
             .connectionInvocation,
             .connectionInvocationResult:
            false
        default:
            true
        }
    }
}
