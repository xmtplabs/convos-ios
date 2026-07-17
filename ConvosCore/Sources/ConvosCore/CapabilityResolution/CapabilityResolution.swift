import ConvosConnections
import Foundation

/// A persisted decision binding `(subject, conversationId, capability, grantedToInboxId)`
/// to one or more providers.
///
/// `grantedToInboxId` scopes the grant to a single agent within the conversation. Two
/// agents in the same conversation have independent rows; one's resolution doesn't
/// authorize the other. The cardinality matrix below applies *within* each row:
///
/// | `allowsReadFederation` | verb     | size  |
/// |------------------------|----------|-------|
/// | `false`                | `.read`  | 1     |
/// | `false`                | writes   | 1     |
/// | `true`                 | `.read`  | ≥ 1   |
/// | `true`                 | writes   | 1     |
///
/// `CapabilityResolver` validates set arity on `setResolution` and throws
/// `ResolutionInconsistent` if a caller hands it a malformed set.
public struct CapabilityResolution: Sendable, Equatable, Hashable {
    public let subject: CapabilitySubject
    public let conversationId: String
    public let capability: ConnectionCapability
    public let grantedToInboxId: String
    public let providerIds: Set<ProviderID>

    public init(
        subject: CapabilitySubject,
        conversationId: String,
        capability: ConnectionCapability,
        grantedToInboxId: String,
        providerIds: Set<ProviderID>
    ) {
        self.subject = subject
        self.conversationId = conversationId
        self.capability = capability
        self.grantedToInboxId = grantedToInboxId
        self.providerIds = providerIds
    }
}

public enum CapabilityResolutionError: Error, LocalizedError, Equatable {
    /// The set's cardinality doesn't match what the subject + verb allows.
    case resolutionInconsistent(reason: String)

    public var errorDescription: String? {
        switch self {
        case .resolutionInconsistent(let reason):
            return reason
        }
    }
}

/// Validates a proposed resolution set against the subject's federation flag and the
/// capability verb shape. Centralized so the resolver, GRDB layer, and any wire-decode
/// path all enforce the same rule.
public enum CapabilityResolutionValidator {
    public static func validate(
        providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability
    ) throws {
        if providerIds.isEmpty {
            throw CapabilityResolutionError.resolutionInconsistent(
                reason: "Resolution provider set must not be empty for (\(subject), \(capability))."
            )
        }
        if providerIds.count > 1 {
            // Writes never federate, regardless of subject.
            if capability.isWrite {
                throw CapabilityResolutionError.resolutionInconsistent(
                    reason: "Write verb '\(capability.rawValue)' on subject '\(subject)' must resolve to exactly one provider, got \(providerIds.count)."
                )
            }
            // Reads federate only on subjects that opt in.
            if !subject.allowsReadFederation {
                throw CapabilityResolutionError.resolutionInconsistent(
                    reason: "Subject '\(subject)' does not allow read federation; resolution must be size 1, got \(providerIds.count)."
                )
            }
        }
    }
}
