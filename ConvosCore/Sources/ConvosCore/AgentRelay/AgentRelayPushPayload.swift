import Foundation

/// The completion push: `notificationType`, `requestId`, `provider`, and a
/// scoped `apiJWT`. Carries no result content.
public enum AgentRelayPushPayload {
    public static let notificationType: String = "AgentRelay"

    public struct Parsed: Equatable, Sendable {
        public let requestId: String
        public let provider: ExternalAgentProvider?
        public let apiJWT: String
    }

    public static func parse(_ userInfo: [AnyHashable: Any]) -> Parsed? {
        guard userInfo["notificationType"] as? String == notificationType,
              let requestId = userInfo["requestId"] as? String, !requestId.isEmpty,
              let apiJWT = userInfo["apiJWT"] as? String, !apiJWT.isEmpty else {
            return nil
        }
        let provider = (userInfo["provider"] as? String).flatMap(ExternalAgentProvider.init(rawValue:))
        return Parsed(requestId: requestId, provider: provider, apiJWT: apiJWT)
    }
}
