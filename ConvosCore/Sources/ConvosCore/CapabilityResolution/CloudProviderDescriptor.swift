import Combine
import ConvosConnections
import Foundation

/// Typed, catalog-derived registration data for one cloud provider: the
/// resolution of a manifest's optional `provider` fields plus its display
/// name. When a descriptor exists for a service, provider registration is
/// built from it; the hardcoded per-service tables in
/// `CloudCapabilityProvider` remain the fallback for backends that predate
/// the fields (see docs/plans/connections-v1-cleanup-map.md).
public struct CloudProviderDescriptor: Sendable, Hashable {
    /// The cloud service slug, parsed from `providerId` ("composio.<serviceId>").
    public let serviceId: String
    public let subject: CapabilitySubject
    public let capabilities: Set<ConnectionCapability>
    public let displayName: String

    public init(
        serviceId: String,
        subject: CapabilitySubject,
        capabilities: Set<ConnectionCapability>,
        displayName: String
    ) {
        self.serviceId = serviceId
        self.subject = subject
        self.capabilities = capabilities
        self.displayName = displayName
    }

    /// Maps a manifest's raw provider fields, or nil when they cannot route
    /// a provider: a non-`composio.` provider id (no other namespace has a
    /// cloud-connection backing) or a subject this build does not know
    /// (registering an unrouted provider would only confuse the picker --
    /// same conservatism as the hardcoded subject table). Unknown capability
    /// strings are dropped; a set left empty collapses to `[.read]`,
    /// matching the table fallback's default.
    public init?(providerInfo: AbilitiesAPI.AbilityProviderInfo, displayName: String) {
        let prefix = "composio."
        guard providerInfo.providerId.hasPrefix(prefix) else { return nil }
        let serviceId = String(providerInfo.providerId.dropFirst(prefix.count))
        guard !serviceId.isEmpty else { return nil }
        guard let subject = CapabilitySubject(rawValue: providerInfo.subject) else { return nil }
        let capabilities = Set(providerInfo.capabilities.compactMap(ConnectionCapability.init(rawValue:)))
        self.init(
            serviceId: serviceId,
            subject: subject,
            capabilities: capabilities.isEmpty ? [.read] : capabilities,
            displayName: displayName
        )
    }

    /// Every routable descriptor in a catalog. Manifests without `provider`
    /// fields, and manifests whose fields fail to route, contribute nothing
    /// (their services stay on the hardcoded fallback).
    public static func descriptors(from catalog: AbilitiesCatalog) -> [CloudProviderDescriptor] {
        catalog.abilities.compactMap { (ability: AbilitiesAPI.Ability) -> CloudProviderDescriptor? in
            guard let providerInfo = ability.provider else { return nil }
            return CloudProviderDescriptor(
                providerInfo: providerInfo,
                displayName: ability.displayName.resolved()
            )
        }
    }
}

/// Process-wide holder for the latest catalog-derived descriptors, bridging
/// the abilities catalog (fetched by `LiveAbilitiesService`) to capability
/// provider registration (run by `SessionManager`'s bootstrap) without
/// coupling the two directly. `updatesPublisher` fires after each change so
/// the bootstrap can re-sync the registry.
public final class CloudProviderDescriptorStore: @unchecked Sendable {
    public static let shared: CloudProviderDescriptorStore = CloudProviderDescriptorStore()

    private let lock: NSLock = NSLock()
    private var descriptorsByServiceId: [String: CloudProviderDescriptor] = [:]
    private let updatesSubject: PassthroughSubject<Void, Never> = PassthroughSubject()

    public init() {}

    public var updatesPublisher: AnyPublisher<Void, Never> {
        updatesSubject.eraseToAnyPublisher()
    }

    public var current: [CloudProviderDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return Array(descriptorsByServiceId.values)
    }

    public func descriptor(for serviceId: String) -> CloudProviderDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptorsByServiceId[serviceId]
    }

    /// Replaces the stored set. Publishes only on an actual change so
    /// repeated identical catalog fetches don't thrash registry syncs.
    public func update(_ descriptors: [CloudProviderDescriptor]) {
        let new = Dictionary(descriptors.map { ($0.serviceId, $0) }) { _, last in last }
        lock.lock()
        let changed = new != descriptorsByServiceId
        descriptorsByServiceId = new
        lock.unlock()
        if changed {
            updatesSubject.send(())
        }
    }

    /// Account-wipe hygiene: drops catalog-derived registrations so a
    /// re-paired account starts from the hardcoded fallback until its own
    /// catalog arrives.
    public func clear() {
        update([])
    }
}
