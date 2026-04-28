import ConvosConnections
import Foundation

/// Snapshots the registry + resolver state into the on-the-wire `CapabilityManifest`
/// shape. Stateless; the writer that hooks into `ProfileUpdate` calls this whenever a
/// republish is warranted.
public struct CapabilityManifestBuilder: Sendable {
    public init() {}

    /// Build the manifest for one conversation. Walks every subject, every registered
    /// provider, and every capability verb the provider declares — for each verb, looks
    /// up the resolution and marks `resolved[verb] = true` if this provider is in the
    /// resolution set.
    ///
    /// Provider-list ordering is alphabetical by `id.rawValue` so re-publishes with
    /// equivalent state produce byte-identical JSON (no spurious `ProfileUpdate` writes).
    public func build(
        registry: any CapabilityProviderRegistry,
        resolver: any CapabilityResolver,
        conversationId: String
    ) async -> CapabilityManifest {
        var entries: [CapabilityManifest.Entry] = []

        for subject in CapabilitySubject.allCases {
            let providers = await registry.providers(for: subject)
            // Cache the resolutions for this subject — every provider needs to consult
            // the same per-verb sets, no point fetching them N times.
            let resolutionsByCapability = await resolutions(
                for: subject,
                conversationId: conversationId,
                resolver: resolver
            )

            for provider in providers {
                let linked = await provider.linkedByUser
                let available = await provider.available
                let capabilities = ConnectionCapability.allCases
                    .filter { provider.capabilities.contains($0) }
                let resolved: [ConnectionCapability: Bool] = capabilities.reduce(into: [:]) { acc, verb in
                    acc[verb] = resolutionsByCapability[verb]?.contains(provider.id) ?? false
                }
                entries.append(
                    CapabilityManifest.Entry(
                        id: provider.id,
                        subject: subject,
                        displayName: provider.displayName,
                        available: available,
                        linked: linked,
                        capabilities: capabilities,
                        resolved: resolved
                    )
                )
            }
        }

        entries.sort(by: { $0.id.rawValue < $1.id.rawValue })
        return CapabilityManifest(providers: entries)
    }

    private func resolutions(
        for subject: CapabilitySubject,
        conversationId: String,
        resolver: any CapabilityResolver
    ) async -> [ConnectionCapability: Set<ProviderID>] {
        var result: [ConnectionCapability: Set<ProviderID>] = [:]
        for capability in ConnectionCapability.allCases {
            let providers = await resolver.resolution(
                subject: subject,
                capability: capability,
                conversationId: conversationId
            )
            if !providers.isEmpty {
                result[capability] = providers
            }
        }
        return result
    }
}
