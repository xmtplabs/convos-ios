import Foundation

public enum AgentVerification: Codable, Hashable, Sendable {
    case unverified
    case verified(Issuer)

    public enum Issuer: String, Codable, Hashable, Sendable {
        case convos
        case userOAuth = "user-oauth"
        case unknown
    }

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var isConvosAssistant: Bool {
        self == .verified(.convos)
    }

    public var isUserOAuthAgent: Bool {
        self == .verified(.userOAuth)
    }

    public var issuer: Issuer? {
        switch self {
        case .unverified:
            return nil
        case .verified(let issuer):
            return issuer
        }
    }
}
