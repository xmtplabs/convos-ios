import ConvosConnections
import Foundation

/// Device → agent reply to a `CapabilityRequest`. Always emitted, even on cancel/deny,
/// so the agent can correlate by `requestId` and stop waiting.
///
/// Wire-typed under `convos.org/capability_request_result/1.0`.
public struct CapabilityRequestResult: Codable, Sendable, Hashable {
    public static let supportedVersion: Int = 1
    public static let maxProviders: Int = 16
    public static let maxAvailableActions: Int = 64

    public enum Status: String, Codable, Sendable {
        case approved
        case denied
        case cancelled
    }

    public let version: Int
    public let requestId: String
    public let status: Status
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    /// Empty for `.denied` / `.cancelled`. For `.approved`, size is 1 for non-federating
    /// subjects and write verbs, ≥ 1 for federating-subject reads. The set is *what the
    /// resolver actually persisted* — agents that supplied a `preferredProviders` hint
    /// should compare against this to confirm their hint was honored.
    public let providers: [ProviderID]
    /// Action schemas compatible with the approved capability, filtered to the providers
    /// returned above. Empty for `.denied` / `.cancelled`.
    public let availableActions: [AvailableAction]

    public init(
        version: Int = CapabilityRequestResult.supportedVersion,
        requestId: String,
        status: Status,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        providers: [ProviderID] = [],
        availableActions: [AvailableAction] = []
    ) {
        self.version = version
        self.requestId = requestId
        self.status = status
        self.subject = subject
        self.capability = capability
        self.providers = Self.truncatedProviders(providers)
        self.availableActions = Self.truncatedAvailableActions(availableActions)
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestId, status, subject, capability, providers, availableActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.status = try container.decode(Status.self, forKey: .status)
        self.subject = try container.decode(CapabilitySubject.self, forKey: .subject)
        self.capability = try container.decode(ConnectionCapability.self, forKey: .capability)
        let rawProviders = try container.decodeIfPresent([ProviderID].self, forKey: .providers) ?? []
        let rawAvailableActions = try container.decodeIfPresent([AvailableAction].self, forKey: .availableActions) ?? []
        self.providers = Self.truncatedProviders(rawProviders)
        self.availableActions = Self.truncatedAvailableActions(rawAvailableActions)
    }

    private static func truncatedProviders(_ providers: [ProviderID]) -> [ProviderID] {
        guard providers.count > maxProviders else { return providers }
        return Array(providers.prefix(maxProviders))
    }

    private static func truncatedAvailableActions(_ actions: [AvailableAction]) -> [AvailableAction] {
        guard actions.count > maxAvailableActions else { return actions }
        return Array(actions.prefix(maxAvailableActions))
    }
}

public extension CapabilityRequestResult {
    struct AvailableAction: Codable, Sendable, Hashable {
        public let providerId: ProviderID
        public let kind: ConnectionKind
        public let actionName: String
        public let summary: String
        public let inputs: [Parameter]
        public let outputs: [Parameter]

        public init(
            providerId: ProviderID,
            kind: ConnectionKind,
            actionName: String,
            summary: String,
            inputs: [Parameter],
            outputs: [Parameter]
        ) {
            self.providerId = providerId
            self.kind = kind
            self.actionName = actionName
            self.summary = summary
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    struct Parameter: Codable, Sendable, Hashable {
        public let name: String
        public let type: String
        public let description: String
        public let isRequired: Bool

        public init(name: String, type: String, description: String, isRequired: Bool) {
            self.name = name
            self.type = type
            self.description = description
            self.isRequired = isRequired
        }
    }
}
