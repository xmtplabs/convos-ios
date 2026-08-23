import Foundation

// MARK: - MessageContentType

public enum MessageContentType: String, Codable, Sendable {
    case text, emoji, attachments, update, invite
    case agentShare // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case linkPreview // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case assistantJoinRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionGrantRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case capabilityRequest // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case capabilityRequestResult // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionEvent // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionInvocation // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionInvocationResult // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case connectionPayload // swiftlint:disable:this raw_value_for_camel_cased_codable_enum

    var marksConversationAsUnread: Bool {
        switch self {
        case .update,
             .assistantJoinRequest,
             .connectionGrantRequest,
             .capabilityRequestResult,
             .connectionEvent,
             .connectionInvocation,
             .connectionInvocationResult,
             .connectionPayload:
            false
        default:
            // capabilityRequest deliberately marks unread: a connect request
            // in the member's 1:1 agent conversation is discovered through
            // the Agent tab's unread dot, so the pill arriving must light it.
            true
        }
    }
}
