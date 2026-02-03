import Foundation

/// Errors that can occur in the CLI
enum CLIError: LocalizedError {
    case conversationNotFound(String)
    case messageNotFound(String)
    case invalidInviteSlug(String)
    case joinFailed(String)
    case sendFailed(String)
    case notAuthenticated
    case timeout(seconds: Int)
    case inviteNotFound(conversationId: String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .invalidInviteSlug(let reason):
            return "Invalid invite slug: \(reason)"
        case .joinFailed(let reason):
            return "Failed to join conversation: \(reason)"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        case .notAuthenticated:
            return "Not authenticated. Please set up your identity first."
        case .timeout(let seconds):
            return "Operation timed out after \(seconds) seconds"
        case .inviteNotFound(let conversationId):
            return "No invite found for conversation: \(conversationId)"
        }
    }
}
