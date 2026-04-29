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
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    public let rationale: String
    public let preferredProviders: [ProviderID]?

    public init(
        version: Int = CapabilityRequest.supportedVersion,
        requestId: String,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        rationale: String,
        preferredProviders: [ProviderID]? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.subject = subject
        self.capability = capability
        self.rationale = Self.truncatedRationale(rationale)
        self.preferredProviders = Self.truncatedProviders(preferredProviders)
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestId, subject, capability, rationale, preferredProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.subject = try container.decode(CapabilitySubject.self, forKey: .subject)
        self.capability = try container.decode(ConnectionCapability.self, forKey: .capability)
        let rawRationale = try container.decode(String.self, forKey: .rationale)
        self.rationale = Self.truncatedRationale(rawRationale)
        let rawPreferred = try container.decodeIfPresent([ProviderID].self, forKey: .preferredProviders)
        self.preferredProviders = Self.truncatedProviders(rawPreferred)
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
