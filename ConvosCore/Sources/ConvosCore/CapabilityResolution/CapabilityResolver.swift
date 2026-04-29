import ConvosConnections
import Foundation

/// The coordinator that sits between incoming `capability_request` /
/// `ConnectionInvocation` messages and the two underlying systems
/// (`ConvosConnections`, cloud OAuth).
///
/// Belongs to neither package; lives in ConvosCore so it can refer to both subsystems by
/// type without inducing a cycle.
public protocol CapabilityResolver: Sendable {
    /// Every provider currently registered for this subject, regardless of whether the
    /// user has linked it.
    func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider]

    /// What the user picked previously for this `(subject, conversation, capability)`.
    /// Empty set means they've never been asked for this verb.
    func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Set<ProviderID>

    /// User has just approved the picker / confirmation card. Validates the set against
    /// the subject's federation flag and the verb shape and throws
    /// `CapabilityResolutionError.resolutionInconsistent` if malformed.
    func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws

    /// Clear a resolution for one verb (e.g. user revoked write access in Conversation
    /// Info but kept reads enabled).
    func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws

    /// Clear every verb's resolution for a subject in a conversation (user toggled the
    /// subject off entirely from Conversation Info).
    func clearAllResolutions(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws

    /// Remove a single provider from any resolution rows that reference it. Called when a
    /// provider is unlinked (cloud OAuth revoked, device permission removed). If a row's
    /// resulting set is empty, the row is deleted; otherwise the row's set shrinks.
    func removeProviderFromAllResolutions(_ providerId: ProviderID) async throws
}

/// In-memory `CapabilityResolver` for tests and bring-up scenarios. The production
/// implementation will back this with GRDB and emit changes for the manifest writer.
public actor InMemoryCapabilityResolver: CapabilityResolver {
    private let registry: any CapabilityProviderRegistry
    private var resolutions: [Key: Set<ProviderID>] = [:]

    private struct Key: Hashable {
        let subject: CapabilitySubject
        let conversationId: String
        let capability: ConnectionCapability
    }

    public init(registry: any CapabilityProviderRegistry) {
        self.registry = registry
    }

    public func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider] {
        await registry.providers(for: subject)
    }

    public func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Set<ProviderID> {
        resolutions[Key(subject: subject, conversationId: conversationId, capability: capability)] ?? []
    }

    public func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {
        try CapabilityResolutionValidator.validate(
            providerIds: providerIds,
            subject: subject,
            capability: capability
        )
        resolutions[Key(subject: subject, conversationId: conversationId, capability: capability)] = providerIds
    }

    public func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {
        resolutions.removeValue(forKey: Key(subject: subject, conversationId: conversationId, capability: capability))
    }

    public func clearAllResolutions(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws {
        resolutions = resolutions.filter { key, _ in
            !(key.subject == subject && key.conversationId == conversationId)
        }
    }

    public func removeProviderFromAllResolutions(_ providerId: ProviderID) async throws {
        for (key, providerIds) in resolutions {
            guard providerIds.contains(providerId) else { continue }
            let shrunk = providerIds.subtracting([providerId])
            if shrunk.isEmpty {
                resolutions.removeValue(forKey: key)
            } else {
                resolutions[key] = shrunk
            }
        }
    }
}
