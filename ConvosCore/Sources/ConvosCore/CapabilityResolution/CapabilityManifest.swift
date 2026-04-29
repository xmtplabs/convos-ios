import ConvosConnections
import Foundation

/// On-the-wire shape published under `profile.metadata["connections"]` on each sender's
/// own `ProfileUpdate`. Encodes everything the agent runtime needs to know about which
/// providers are available, which are routed where, and which verbs are granted in this
/// conversation.
public struct CapabilityManifest: Codable, Sendable, Equatable, Hashable {
    public static let supportedVersion: Int = 1

    public let version: Int
    public let providers: [Entry]

    public init(version: Int = CapabilityManifest.supportedVersion, providers: [Entry]) {
        self.version = version
        self.providers = providers
    }

    public struct Entry: Codable, Sendable, Equatable, Hashable {
        public let id: ProviderID
        public let subject: CapabilitySubject
        public let displayName: String
        /// Framework reachable / cloud service up. `false` here means the agent should
        /// ignore the entry — the provider isn't usable on this device right now.
        public let available: Bool
        /// User has credentials for this provider. `true` for device providers with
        /// permission granted; `true` for cloud providers with an active OAuth grant.
        public let linked: Bool
        /// Verbs this provider supports, encoded as `ConnectionCapability.rawValue`s
        /// (`"read"`, `"write_create"`, etc.).
        public let capabilities: [String]
        /// Per-capability routing flag for this conversation, keyed by
        /// `ConnectionCapability.rawValue`. `true` means the agent should call this
        /// provider when that verb is invoked. For non-federating subjects, all granted
        /// verbs route to the same provider; for federating subjects on `.read`,
        /// multiple providers can have `resolved["read"] == true` simultaneously and the
        /// agent should expect a federated read.
        ///
        /// Keyed by raw value (not the enum directly) because JSONEncoder encodes
        /// `[EnumKey: Value]` dictionaries as an array of pairs, which agents would
        /// have to special-case.
        public let resolved: [String: Bool]

        public init(
            id: ProviderID,
            subject: CapabilitySubject,
            displayName: String,
            available: Bool,
            linked: Bool,
            capabilities: [ConnectionCapability],
            resolved: [ConnectionCapability: Bool]
        ) {
            self.id = id
            self.subject = subject
            self.displayName = displayName
            self.available = available
            self.linked = linked
            self.capabilities = capabilities.map(\.rawValue)
            self.resolved = Dictionary(
                uniqueKeysWithValues: resolved.map { key, value in (key.rawValue, value) }
            )
        }

        /// Reconstruct the resolved map as a typed dictionary. Skips keys that don't
        /// correspond to a known `ConnectionCapability` (forward-compat).
        public var resolvedCapabilities: [ConnectionCapability: Bool] {
            var typed: [ConnectionCapability: Bool] = [:]
            for (key, value) in resolved {
                guard let capability = ConnectionCapability(rawValue: key) else { continue }
                typed[capability] = value
            }
            return typed
        }
    }
}
