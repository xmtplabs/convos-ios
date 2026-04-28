@testable import ConvosCore
import ConvosConnections
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
            makeConnection(serviceId: "google_calendar", serviceName: "Google Calendar")
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
