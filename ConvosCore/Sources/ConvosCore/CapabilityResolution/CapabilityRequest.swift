import ConvosConnections
import Foundation

/// Agent → device "I would like to access your <subject> for <capability>" request.
///
/// Wire-typed under `convos.org/capability_request/1.0`. The client routes this into the
/// resolver, which surfaces a picker / confirmation card; once the user approves or
/// denies, the device replies with `CapabilityRequestResult`.
public struct CapabilityRequest: Codable, Sendable, Hashable {
    /// Highest schema version this client understands. Decoders reject newer versions so
    /// hostile or future senders can't get past type-check by smuggling fields the picker
    /// doesn't know how to render.
    public static let supportedVersion: Int = 1

    /// Cap on the `rationale` field. Anything longer is truncated on decode so the picker
    /// card doesn't get bloated by a hostile sender.
    public static let maxRationaleLength: Int = 500

    /// Cap on the `preferredProviders` list to prevent quadratic picker-render times if a
    /// sender fills the array.
    public static let maxPreferredProviders: Int = 16

    public let version: Int
    public let requestId: String
    /// Inbox id of the agent making the request. Bound on the wire (rather than relying
    /// on the XMTP envelope's `senderInboxId` alone) so the runtime, CLI, and iOS all
    /// agree on the asking identity even when the message hasn't been verified yet —
    /// and so that the persisted grant row, the connection_event credit, and the
    /// resolver lookup all key off the same value the sender chose to publish.
    public let askerInboxId: String
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    public let rationale: String
    public let preferredProviders: [ProviderID]?

    public init(
        version: Int = CapabilityRequest.supportedVersion,
        requestId: String,
        askerInboxId: String,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        rationale: String,
        preferredProviders: [ProviderID]? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.askerInboxId = askerInboxId
        self.subject = subject
        self.capability = capability
        self.rationale = Self.truncatedRationale(rationale)
        self.preferredProviders = Self.truncatedProviders(preferredProviders)
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestId, askerInboxId, subject, capability, rationale, preferredProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.supportedVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported version \(version); max supported is \(Self.supportedVersion)"
            )
        }
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.askerInboxId = try container.decode(String.self, forKey: .askerInboxId)
        self.subject = try container.decode(CapabilitySubject.self, forKey: .subject)
        self.capability = try container.decode(ConnectionCapability.self, forKey: .capability)
        let rawRationale = try container.decode(String.self, forKey: .rationale)
        self.rationale = Self.truncatedRationale(rawRationale)
        // Translate Composio toolkit-slug wire form to canonical for internal use.
        let wirePreferred = try container.decodeIfPresent([String].self, forKey: .preferredProviders)
        let canonicalPreferred = wirePreferred?.map { ProviderID(wireForm: $0) }
        self.preferredProviders = Self.truncatedProviders(canonicalPreferred)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(askerInboxId, forKey: .askerInboxId)
        try container.encode(subject, forKey: .subject)
        try container.encode(capability, forKey: .capability)
        try container.encode(rationale, forKey: .rationale)
        // Emit Composio toolkit slug on the wire so agents can pass straight to
        // `tools.execute` without translation.
        let wirePreferred = preferredProviders?.map { $0.wireFormRawValue }
        try container.encodeIfPresent(wirePreferred, forKey: .preferredProviders)
    }

    private static func truncatedRationale(_ rationale: String) -> String {
        guard rationale.count > maxRationaleLength else { return rationale }
        return String(rationale.prefix(maxRationaleLength))
    }

    private static func truncatedProviders(_ providers: [ProviderID]?) -> [ProviderID]? {
        guard let providers else { return nil }
        guard providers.count > maxPreferredProviders else { return providers }
        return Array(providers.prefix(maxPreferredProviders))
    }
}
