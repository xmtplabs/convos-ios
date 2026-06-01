import Foundation

/// A message whose body is an agent-share link. The parallel of
/// `MessageInvite`, but it stores only what the link itself carries -- an
/// `identifier` the backend resolves and the original `url` -- because, unlike
/// an invite, an agent-share link has no embedded signed metadata. The
/// agent's display name / emoji / description are fetched on demand by an
/// `AgentShareResolving` at render time.
public struct MessageAgentShare: Sendable, Hashable, Codable {
    public let identifier: String
    public let url: String

    public init(identifier: String, url: String) {
        self.identifier = identifier
        self.url = url
    }

    /// Attempts to parse a `MessageAgentShare` from text content. Returns
    /// `nil` if the text is not a recognized agent-share link. Mirrors
    /// `MessageInvite.from(text:)` so message classification can call both
    /// the same way.
    public static func from(text: String) -> MessageAgentShare? {
        guard let parsed = AgentShareURL.from(text: text) else { return nil }
        return MessageAgentShare(identifier: parsed.identifier, url: parsed.url)
    }

    public static var mock: MessageAgentShare {
        .init(identifier: "11111111-1111-4111-8111-111111111111", url: "convos://template/11111111-1111-4111-8111-111111111111")
    }
}
