import ConvosConnections
import Foundation

/// Helpers for registering / unregistering `CapabilityProvider`s with a registry.
///
/// Designed for the session-bootstrap path: the host calls `registerDeviceProviders`
/// once with whatever subset of `ConnectionKind`s the running build supports, and calls
/// `syncCloudProviders` whenever the cloud-connection list changes (link, unlink,
/// status flip).
public enum CapabilityProviderBootstrap {
    /// Register a `DeviceCapabilityProvider` for each spec. The host is responsible for
    /// supplying the `linkedByUser` and `available` closures — those query the actual
    /// iOS framework permission state, which the resolver layer doesn't know about.
    ///
    /// Idempotent: re-registering an existing id replaces the previous provider entry
    /// (and emits a `.linkedStateChanged` event so subscribed pickers refresh).
    public static func registerDeviceProviders(
        specs: [DeviceCapabilityProvider.Spec] = DeviceCapabilityProvider.defaultSpecs,
        registry: any CapabilityProviderRegistry,
        linkedByUser: @Sendable (ConnectionKind) -> @Sendable () async -> Bool,
        available: @Sendable (ConnectionKind) -> @Sendable () async -> Bool = { _ in { true } }
    ) async {
        for spec in specs {
            let provider = DeviceCapabilityProvider(
                id: spec.id,
                subject: spec.subject,
                displayName: spec.displayName,
                iconName: spec.iconName,
                capabilities: spec.capabilities,
                linkedByUser: linkedByUser(spec.kind),
                available: available(spec.kind)
            )
            await registry.register(provider)
        }
    }

    /// Diff the current cloud-connection set against the provided `connections`, register
    /// new ones, refresh existing ones (so `linkedSnapshot` reflects the latest status),
    /// and unregister anything that disappeared.
    ///
    /// Call this after every cloud-side state change: a fresh `connect`, a `disconnect`,
    /// a `refreshConnections` that observed a status flip.
    public static func syncCloudProviders(
        connections: [CloudConnection],
        registry: any CapabilityProviderRegistry
    ) async {
        // Compute the desired set of provider ids from the current connections list.
        let desiredProviders: [(ProviderID, CloudCapabilityProvider)] = connections.compactMap { connection in
            guard let provider = CloudCapabilityProvider.from(connection) else { return nil }
            return (provider.id, provider)
        }
        let desiredIds = Set(desiredProviders.map(\.0))

        // Drop everything currently registered under the `composio.` namespace that isn't
        // in the desired set. We touch only cloud providers so device registrations
        // (registered separately at boot) stay put.
        let existingCloudIds = await cloudProviderIds(in: registry)
        for id in existingCloudIds where !desiredIds.contains(id) {
            await registry.unregister(id: id)
        }

        // Register / refresh every desired provider. `register` replaces any existing
        // entry with the same id and emits `.linkedStateChanged` for replacements.
        for (_, provider) in desiredProviders {
            await registry.register(provider)
        }
    }

    private static func cloudProviderIds(in registry: any CapabilityProviderRegistry) async -> [ProviderID] {
        var ids: [ProviderID] = []
        for subject in CapabilitySubject.allCases {
            let subjectProviders = await registry.providers(for: subject)
            for provider in subjectProviders where provider.id.rawValue.hasPrefix("composio.") {
                ids.append(provider.id)
            }
        }
        return ids
    }
}
