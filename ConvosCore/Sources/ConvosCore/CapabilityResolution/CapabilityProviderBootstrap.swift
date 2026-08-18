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
                subjectNounPhrase: spec.subjectNounPhrase,
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
    /// `seedServiceIds` lets the host declare a set of services that should always be
    /// represented in the registry — services without an active `CloudConnection` get a
    /// `linked: false` placeholder so the picker can still surface them as candidates
    /// (e.g., for a `connectAndApprove` flow). Active connections always win over their
    /// placeholders.
    ///
    /// Call this after every cloud-side state change: a fresh `connect`, a `disconnect`,
    /// a `refreshConnections` that observed a status flip.
    /// `descriptors` carries catalog-derived registration data (see
    /// `CloudProviderDescriptor`). A service with a descriptor is registered
    /// from it -- the hardcoded tables are not consulted -- and every
    /// descriptor service is implicitly seeded, so a backend-manifest-only
    /// ability gets its placeholder without an iOS change. Services without a
    /// descriptor fall back to the tables exactly as before.
    public static func syncCloudProviders(
        connections: [CloudConnection],
        seedServiceIds: Set<String> = [],
        descriptors: [CloudProviderDescriptor] = [],
        registry: any CapabilityProviderRegistry
    ) async {
        // Compute the desired set of provider ids from the current connections list.
        // Multiple connections sharing a `serviceId` generate the same `ProviderID` and
        // would silently overwrite one another in the registry. Deduplicate up front
        // (last wins, matching the registry's existing semantics) and warn so the
        // collision is visible until provider id disambiguation lands.
        var seenIds: Set<ProviderID> = []
        var seenServiceIds: Set<String> = []
        var desiredProviders: [(ProviderID, CloudCapabilityProvider)] = []
        let descriptorsByServiceId: [String: CloudProviderDescriptor] = Dictionary(
            descriptors.map { ($0.serviceId, $0) }
        ) { _, last in last }
        for connection in connections {
            let descriptor = descriptorsByServiceId[connection.serviceId]
            guard let provider = CloudCapabilityProvider.from(connection, descriptor: descriptor) else {
                // The user linked a service this build can't route to a subject. Without a
                // provider the service is invisible to every agent ask, so say so rather
                // than dropping it silently.
                Log.warning("CapabilityProviderBootstrap: no subject mapping for serviceId \(connection.serviceId) — not registered")
                continue
            }
            if !seenIds.insert(provider.id).inserted {
                Log.warning("CapabilityProviderBootstrap: duplicate ProviderID \(provider.id.rawValue) — only one connection will be registered")
                desiredProviders.removeAll { $0.0 == provider.id }
            }
            desiredProviders.append((provider.id, provider))
            seenServiceIds.insert(connection.serviceId)
        }

        let allSeedIds = seedServiceIds.union(descriptorsByServiceId.keys)
        for serviceId in allSeedIds.sorted() where !seenServiceIds.contains(serviceId) {
            let descriptor = descriptorsByServiceId[serviceId]
            guard let placeholder = CloudCapabilityProvider.placeholder(serviceId: serviceId, descriptor: descriptor) else { continue }
            guard seenIds.insert(placeholder.id).inserted else { continue }
            desiredProviders.append((placeholder.id, placeholder))
        }

        let desiredIds = seenIds

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
