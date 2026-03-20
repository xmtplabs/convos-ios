import Foundation

public enum ConversationAvatarType: Sendable, Equatable {
    case customImage
    case profile(Profile, AgentVerification)
    case clustered([Profile])
    case emoji(String)
    case monogram(String)
}
