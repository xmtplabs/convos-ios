import Foundation

// MARK: - ConversationCustomMetadataError

enum ConversationCustomMetadataError: Error, LocalizedError {
    case randomGenerationFailed
    case invalidLength(Int)
    case invalidInboxIdHex(String)
    case appDataLimitExceeded(limit: Int, actualSize: Int)
    case metadataUpdateFailed

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            return "Failed to generate secure random bytes"
        case .invalidLength(let length):
            return "Invalid length for random string generation: \(length). Length must be positive."
        case .invalidInboxIdHex(let inboxId):
            return "Failed to convert MemberProfile to ConversationProfile - invalid inbox ID hex: \(inboxId)"
        case let .appDataLimitExceeded(limit, actualSize):
            return "Conversation metadata exceeds \(limit) byte limit: \(actualSize) bytes"
        case .metadataUpdateFailed:
            return "Failed to update conversation metadata after multiple retries"
        }
    }
}

// MARK: - DisplayError Conformance

extension ConversationCustomMetadataError: DisplayError {
    var title: String {
        switch self {
        case .appDataLimitExceeded: return "Too much data"
        case .randomGenerationFailed: return "Security error"
        case .invalidLength: return "Invalid data"
        case .invalidInboxIdHex: return "Invalid profile"
        case .metadataUpdateFailed: return "Update failed"
        }
    }

    var description: String {
        switch self {
        case let .appDataLimitExceeded(limit, actualSize):
            return "Conversation metadata is too large, \(actualSize / 1024)kb for \(limit / 1024)kb limit."
        case .randomGenerationFailed:
            return "Failed to generate secure identifier. Please try again."
        case .invalidLength(let length):
            return "Invalid data length: \(length)"
        case .invalidInboxIdHex:
            return "Invalid member profile identifier"
        case .metadataUpdateFailed:
            return "Failed to update conversation. Please try again."
        }
    }
}
