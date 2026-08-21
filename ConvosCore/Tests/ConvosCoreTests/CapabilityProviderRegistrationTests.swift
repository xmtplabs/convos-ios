import Combine
import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

@Suite("DeviceCapabilityProvider")
struct DeviceCapabilityProviderTests {
    @Test("default specs map every routable kind to a unique subject and id")
    func defaultSpecsCoverage() {
        let specs = DeviceCapabilityProvider.defaultSpecs
        let kinds = Set(specs.map(\.kind))
        let ids = Set(specs.map(\.id.rawValue))
        // No duplicate kinds or ids in the catalog.
        #expect(kinds.count == specs.count)
        #expect(ids.count == specs.count)
        // .motion intentionally excluded — sensor-only, not a user-facing subject.
        #expect(kinds.contains(.motion) == false)
    }

    @Test("default specs route fitness verbs to .health")
    func healthRoutesToFitness() {
        let healthSpec = DeviceCapabilityProvider.defaultSpecs.first { $0.kind == .health }
        #expect(healthSpec?.subject == .fitness)
    }

    @Test("linkedByUser closure is queried lazily")
    func linkedByUserLazy() async {
        let counter = Counter()
        let provider = DeviceCapabilityProvider(
            id: ProviderID(rawValue: "device.calendar"),
            subject: .calendar,
            displayName: "Apple Calendar",
            iconName: "calendar",
            capabilities: [.read],
            linkedByUser: {
                await counter.tick()
                return true
            }
        )
        // Construction does not call the closure.
        let initial = await counter.value
        #expect(initial == 0)
        // Each access does.
        let first = await provider.linkedByUser
        let second = await provider.linkedByUser
        #expect(first == true)
        #expect(second == true)
        let final = await counter.value
        #expect(final == 2)
    }

    private actor Counter {
        var value: Int = 0
        func tick() { value += 1 }
    }
}

@Suite("CloudCapabilityProvider")
struct CloudCapabilityProviderTests {
    private func makeConnection(
        serviceId: String,
        serviceName: String = "Service",
        status: CloudConnectionStatus = .active
    ) -> CloudConnection {
        CloudConnection(
            id: "conn-\(serviceId)",
            serviceId: serviceId,
            serviceName: serviceName,
            provider: .composio,
            composioEntityId: "entity-x",
            composioConnectionId: "composio-y",
            status: status,
            connectedAt: Date()
        )
    }

    @Test("Strava maps to .fitness with read-only capabilities")
    func stravaProvider() {
        let provider = CloudCapabilityProvider.from(makeConnection(serviceId: "strava", serviceName: "Strava"))
        let unwrapped = try? #require(provider)
        #expect(unwrapped?.subject == .fitness)
        #expect(unwrapped?.capabilities == [.read])
        #expect(unwrapped?.id.rawValue == "composio.strava")
    }

    @Test("Google Calendar maps to .calendar with full verb support")
    func googleCalendarProvider() {
        let provider = CloudCapabilityProvider.from(
            makeConnection(serviceId: "googlecalendar", serviceName: "Google Calendar")
        )
        let unwrapped = try? #require(provider)
        #expect(unwrapped?.subject == .calendar)
        #expect(unwrapped?.capabilities == [.read, .writeCreate, .writeUpdate, .writeDelete])
    }

    @Test("unknown service returns nil — we don't surface unrouted providers")
    func unknownServiceIsNil() {
        let provider = CloudCapabilityProvider.from(makeConnection(serviceId: "obscure_thing"))
        #expect(provider == nil)
    }

    @Test("expired connection produces a provider with linked=false")
    func expiredIsLinkedFalse() async {
        let provider = CloudCapabilityProvider.from(
            makeConnection(serviceId: "strava", status: .expired)
        )
        let unwrapped = try? #require(provider)
        let linked = await unwrapped?.linkedByUser
        #expect(linked == false)
    }
}

@Suite("CapabilityProviderBootstrap")
struct CapabilityProviderBootstrapTests {
    private func makeConnection(
        serviceId: String,
        status: CloudConnectionStatus = .active,
        suffix: String = ""
    ) -> CloudConnection {
        CloudConnection(
            id: "conn-\(serviceId)\(suffix)",
            serviceId: serviceId,
            serviceName: serviceId.capitalized,
            provider: .composio,
            composioEntityId: "entity",
            composioConnectionId: "conn",
            status: status,
            connectedAt: Date()
        )
    }

    @Test("registerDeviceProviders adds one provider per spec")
    func registerDevice() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.registerDeviceProviders(
            specs: [
                DeviceCapabilityProvider.Spec(
                    kind: .calendar,
                    id: ProviderID(rawValue: "device.calendar"),
                    subject: .calendar,
                    displayName: "Apple Calendar",
                    iconName: "calendar",
                    capabilities: [.read]
                ),
            ],
            registry: registry,
            linkedByUser: { _ in { true } }
        )
        let providers = await registry.providers(for: .calendar)
        #expect(providers.map(\.id.rawValue) == ["device.calendar"])
    }

    @Test("syncCloudProviders adds new linked services")
    func syncAddsNew() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava")],
            registry: registry
        )
        let providers = await registry.providers(for: .fitness)
        #expect(providers.map(\.id.rawValue) == ["composio.strava"])
    }

    @Test("syncCloudProviders removes services no longer in the list")
    func syncRemovesStale() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava"), makeConnection(serviceId: "fitbit")],
            registry: registry
        )
        var providers = await registry.providers(for: .fitness)
        #expect(providers.count == 2)

        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava")],
            registry: registry
        )
        providers = await registry.providers(for: .fitness)
        #expect(providers.map(\.id.rawValue) == ["composio.strava"])
    }

    @Test("syncCloudProviders refreshes status when a connection expires")
    func syncRefreshesStatus() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava", status: .active)],
            registry: registry
        )
        var provider = await registry.providers(for: .fitness).first
        var linked = await provider?.linkedByUser
        #expect(linked == true)

        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava", status: .expired)],
            registry: registry
        )
        provider = await registry.providers(for: .fitness).first
        linked = await provider?.linkedByUser
        #expect(linked == false, "registry should hold the refreshed (expired) provider after re-sync")
    }

    @Test("syncCloudProviders skips unknown serviceIds")
    func syncSkipsUnknown() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "obscure_thing")],
            registry: registry
        )
        // Walk every subject, no provider should be registered.
        for subject in CapabilitySubject.allCases {
            let providers = await registry.providers(for: subject)
            #expect(providers.isEmpty, "no provider should be registered for unknown service in \(subject)")
        }
    }

    @Test("syncCloudProviders leaves device providers untouched")
    func syncDoesNotTouchDeviceProviders() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.registerDeviceProviders(
            specs: DeviceCapabilityProvider.defaultSpecs,
            registry: registry,
            linkedByUser: { _ in { true } }
        )
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "strava")],
            registry: registry
        )
        // Device.calendar should still be there.
        let calendar = await registry.providers(for: .calendar)
        #expect(calendar.map(\.id.rawValue) == ["device.calendar"])

        // Empty cloud list should drop strava but leave device.health alone.
        await CapabilityProviderBootstrap.syncCloudProviders(connections: [], registry: registry)
        let fitness = await registry.providers(for: .fitness)
        #expect(fitness.map(\.id.rawValue) == ["device.health"])
    }
}

@Suite("Catalog-driven providers")
struct CatalogDrivenProviderTests {
    private func makeConnection(
        serviceId: String,
        status: CloudConnectionStatus = .active
    ) -> CloudConnection {
        CloudConnection(
            id: "conn-\(serviceId)",
            serviceId: serviceId,
            serviceName: serviceId.capitalized,
            provider: .composio,
            composioEntityId: "entity",
            composioConnectionId: "conn",
            status: status,
            connectedAt: Date()
        )
    }

    private func makeProviderInfo(
        providerId: String = "composio.notion",
        subject: String = "tasks",
        capabilities: [String] = ["read", "write_create"]
    ) -> AbilitiesAPI.AbilityProviderInfo {
        AbilitiesAPI.AbilityProviderInfo(
            providerId: providerId,
            subject: subject,
            capabilities: capabilities
        )
    }

    @Test("descriptor maps providerId, subject, and capabilities")
    func descriptorMapsFields() {
        let descriptor = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(),
            displayName: "Notion"
        )
        #expect(descriptor?.serviceId == "notion")
        #expect(descriptor?.subject == .tasks)
        #expect(descriptor?.capabilities == [.read, .writeCreate])
        #expect(descriptor?.displayName == "Notion")
    }

    @Test("non-composio provider ids do not map")
    func nonComposioIsNil() {
        let descriptor = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(providerId: "device.calendar"),
            displayName: "Calendar"
        )
        #expect(descriptor == nil)
    }

    @Test("an empty serviceId does not map")
    func emptyServiceIdIsNil() {
        let descriptor = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(providerId: "composio."),
            displayName: "Nameless"
        )
        #expect(descriptor == nil)
    }

    @Test("an unknown subject does not map — unrouted providers stay out of the picker")
    func unknownSubjectIsNil() {
        let descriptor = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(subject: "finance"),
            displayName: "Notion"
        )
        #expect(descriptor == nil)
    }

    @Test("unknown capability strings are dropped; an all-unknown list collapses to read")
    func unknownCapabilitiesDrop() {
        let mixed = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(capabilities: ["read", "teleport"]),
            displayName: "Notion"
        )
        #expect(mixed?.capabilities == [.read])
        let allUnknown = CloudProviderDescriptor(
            providerInfo: makeProviderInfo(capabilities: ["teleport"]),
            displayName: "Notion"
        )
        #expect(allUnknown?.capabilities == [.read])
    }

    @Test("placeholder built from a descriptor for a service absent from every hardcoded table")
    func placeholderFromDescriptorOnly() throws {
        let descriptor = try #require(CloudProviderDescriptor(
            providerInfo: makeProviderInfo(),
            displayName: "Notion"
        ))
        // Guard the premise: the hardcoded tables know nothing about this id,
        // so any registration below can only come from the catalog.
        #expect(CloudCapabilityProvider.serviceSubjectMap["notion"] == nil)
        #expect(CloudCapabilityProvider.placeholder(serviceId: "notion") == nil)

        let placeholder = try #require(CloudCapabilityProvider.placeholder(serviceId: "notion", descriptor: descriptor))
        #expect(placeholder.id.rawValue == "composio.notion")
        #expect(placeholder.subject == .tasks)
        #expect(placeholder.capabilities == [.read, .writeCreate])
        #expect(placeholder.displayName == "Notion")
        #expect(placeholder.linkedSnapshot == false)
    }

    @Test("descriptor wins over the hardcoded tables for a table-known service")
    func descriptorOverridesTables() throws {
        let descriptor = try #require(CloudProviderDescriptor(
            providerInfo: makeProviderInfo(
                providerId: "composio.googlecalendar",
                subject: "calendar",
                capabilities: ["read"]
            ),
            displayName: "Calendar (Catalog)"
        ))
        let provider = try #require(CloudCapabilityProvider.from(
            makeConnection(serviceId: "googlecalendar"),
            descriptor: descriptor
        ))
        // The hardcoded table grants the full verb set; the catalog narrowed
        // it to read, and the catalog must win.
        #expect(provider.capabilities == [.read])
        #expect(provider.displayName == "Calendar (Catalog)")
    }

    @Test("sync registers a catalog-only service as a placeholder without a seed entry")
    func syncSeedsFromDescriptors() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let descriptor = try #require(CloudProviderDescriptor(
            providerInfo: makeProviderInfo(),
            displayName: "Notion"
        ))
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [],
            seedServiceIds: [],
            descriptors: [descriptor],
            registry: registry
        )
        let tasks = await registry.providers(for: .tasks)
        #expect(tasks.map(\.id.rawValue) == ["composio.notion"])
    }

    @Test("sync without descriptors falls back to the hardcoded tables")
    func syncFallsBackWithoutDescriptors() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await CapabilityProviderBootstrap.syncCloudProviders(
            connections: [makeConnection(serviceId: "googlecalendar")],
            seedServiceIds: [],
            registry: registry
        )
        let calendar = await registry.providers(for: .calendar)
        let provider = calendar.first { $0.id.rawValue == "composio.googlecalendar" }
        #expect((provider as? CloudCapabilityProvider)?.capabilities == [.read, .writeCreate, .writeUpdate, .writeDelete])
    }

    @Test("descriptors(from:) skips manifests without provider fields")
    func descriptorsFromCatalog() throws {
        let withProvider = try AbilitiesAPI.Ability(
            id: "notion",
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: "Notion"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Tasks and notes"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: [],
            provider: makeProviderInfo()
        )
        let withoutProvider = try AbilitiesAPI.Ability(
            id: "spotify",
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: "Spotify"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Playback"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: []
        )
        let catalog = AbilitiesCatalog(catalogVersion: 1, abilities: [withProvider, withoutProvider])
        let descriptors = CloudProviderDescriptor.descriptors(from: catalog)
        #expect(descriptors.map(\.serviceId) == ["notion"])
        #expect(descriptors.first?.displayName == "Notion")
    }

    @Test("store publishes on change and only on change")
    func storePublishesOnChange() throws {
        let store = CloudProviderDescriptorStore()
        let counter = UpdateCounter()
        let cancellable = store.updatesPublisher.sink { _ in counter.increment() }
        defer { cancellable.cancel() }
        let descriptor = try #require(CloudProviderDescriptor(
            providerInfo: makeProviderInfo(),
            displayName: "Notion"
        ))
        store.update([descriptor])
        #expect(counter.count == 1)
        #expect(store.descriptor(for: "notion") != nil)
        // Identical update: no publish.
        store.update([descriptor])
        #expect(counter.count == 1)
        store.clear()
        #expect(counter.count == 2)
        #expect(store.current.isEmpty)
    }

    private final class UpdateCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }
    }
}
