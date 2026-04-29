@testable import ConvosCore
import ConvosConnections
import Foundation
import Testing

private struct StubProvider: CapabilityProvider {
    let id: ProviderID
    let subject: CapabilitySubject
    let displayName: String
    let iconName: String = ""
    let capabilities: Set<ConnectionCapability>
    let linkedByUserValue: Bool
    let availableValue: Bool

    var linkedByUser: Bool { get async { linkedByUserValue } }
    var available: Bool { get async { availableValue } }
}

@Suite("CapabilityManifest JSON shape")
struct CapabilityManifestJSONShapeTests {
    @Test("resolved encodes as a JSON object keyed by capability rawValue")
    func resolvedIsObjectKeyed() throws {
        let entry = CapabilityManifest.Entry(
            id: ProviderID(rawValue: "device.calendar"),
            subject: .calendar,
            displayName: "Apple Calendar",
            available: true,
            linked: true,
            capabilities: [.read, .writeCreate],
            resolved: [.read: true, .writeCreate: false]
        )
        let manifest = CapabilityManifest(providers: [entry])
        let data = try JSONEncoder().encode(manifest)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(json?["providers"] as? [[String: Any]])
        let resolved = try #require(providers[0]["resolved"] as? [String: Any])
        #expect(resolved["read"] as? Bool == true)
        #expect(resolved["write_create"] as? Bool == false)
    }

    @Test("capabilities encodes as an array of rawValue strings")
    func capabilitiesAsRawValues() throws {
        let entry = CapabilityManifest.Entry(
            id: ProviderID(rawValue: "device.calendar"),
            subject: .calendar,
            displayName: "Apple Calendar",
            available: true,
            linked: true,
            capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete],
            resolved: [:]
        )
        let manifest = CapabilityManifest(providers: [entry])
        let data = try JSONEncoder().encode(manifest)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(json?["providers"] as? [[String: Any]])
        let capabilities = try #require(providers[0]["capabilities"] as? [String])
        #expect(capabilities == ["read", "write_create", "write_update", "write_delete"])
    }

    @Test("manifest round-trips through JSON")
    func roundTrip() throws {
        let manifest = CapabilityManifest(providers: [
            CapabilityManifest.Entry(
                id: ProviderID(rawValue: "composio.strava"),
                subject: .fitness,
                displayName: "Strava",
                available: true,
                linked: true,
                capabilities: [.read],
                resolved: [.read: true]
            ),
        ])
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CapabilityManifest.self, from: encoded)
        #expect(decoded == manifest)
    }

    @Test("resolvedCapabilities convenience reconstructs the typed dict")
    func resolvedCapabilitiesAccessor() {
        let entry = CapabilityManifest.Entry(
            id: ProviderID(rawValue: "composio.strava"),
            subject: .fitness,
            displayName: "Strava",
            available: true,
            linked: true,
            capabilities: [.read],
            resolved: [.read: true]
        )
        #expect(entry.resolvedCapabilities == [.read: true])
    }

    @Test("resolvedCapabilities ignores unknown verb keys")
    func resolvedCapabilitiesIgnoresUnknown() throws {
        // Build a synthetic JSON with an unknown verb to simulate forward-compat.
        let json = """
        {
          "version": 1,
          "providers": [{
            "id": "composio.strava",
            "subject": "fitness",
            "displayName": "Strava",
            "available": true,
            "linked": true,
            "capabilities": ["read", "future_verb"],
            "resolved": {"read": true, "future_verb": true}
          }]
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(CapabilityManifest.self, from: json)
        let entry = try #require(manifest.providers.first)
        #expect(entry.resolvedCapabilities == [.read: true])
    }
}

@Suite("CapabilityManifestBuilder")
struct CapabilityManifestBuilderTests {
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.google_calendar")

    @Test("empty registry produces empty providers list")
    func emptyRegistry() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        #expect(manifest.providers.isEmpty)
        #expect(manifest.version == CapabilityManifest.supportedVersion)
    }

    @Test("provider entry includes linked/available/capabilities")
    func providerMetadata() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let provider = StubProvider(
            id: appleCalendar,
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read, .writeCreate],
            linkedByUserValue: true,
            availableValue: true
        )
        await registry.register(provider)
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let entry = try? #require(manifest.providers.first)
        #expect(entry?.id == appleCalendar)
        #expect(entry?.subject == .calendar)
        #expect(entry?.linked == true)
        #expect(entry?.available == true)
        #expect(entry?.capabilities == ["read", "write_create"])
        // No resolution → all resolved flags false.
        #expect(entry?.resolved == ["read": false, "write_create": false])
    }

    @Test("resolved map reflects resolutions for this conversation")
    func resolvedReflectsResolution() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let provider = StubProvider(
            id: appleCalendar,
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read, .writeCreate],
            linkedByUserValue: true,
            availableValue: true
        )
        await registry.register(provider)
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1"
        )

        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let entry = try #require(manifest.providers.first)
        #expect(entry.resolved == ["read": true, "write_create": false])
    }

    @Test("federated read marks both providers as resolved.read=true")
    func federatedReadFlagsBoth() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let strava = StubProvider(
            id: strava,
            subject: .fitness,
            displayName: "Strava",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        let fitbit = StubProvider(
            id: fitbit,
            subject: .fitness,
            displayName: "Fitbit",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        await registry.register(strava)
        await registry.register(fitbit)
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [strava.id, fitbit.id],
            subject: .fitness,
            capability: .read,
            conversationId: "conv-1"
        )

        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let resolvedReads = manifest.providers.map { $0.resolved["read"] }
        #expect(resolvedReads == [true, true])
    }

    @Test("resolution for one conversation does not appear on another's manifest")
    func resolutionScopedToConversation() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let provider = StubProvider(
            id: appleCalendar,
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        await registry.register(provider)
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1"
        )

        let conv1Manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let conv2Manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-2"
        )
        #expect(conv1Manifest.providers.first?.resolved["read"] == true)
        #expect(conv2Manifest.providers.first?.resolved["read"] == false)
    }

    @Test("provider entries sorted alphabetically by id for stable JSON")
    func sortedById() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let strava = StubProvider(
            id: strava,
            subject: .fitness,
            displayName: "Strava",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        let fitbit = StubProvider(
            id: fitbit,
            subject: .fitness,
            displayName: "Fitbit",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        let appleCalendar = StubProvider(
            id: appleCalendar,
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read],
            linkedByUserValue: true,
            availableValue: true
        )
        // Register in non-sorted order.
        await registry.register(strava)
        await registry.register(appleCalendar)
        await registry.register(fitbit)

        let resolver = InMemoryCapabilityResolver(registry: registry)
        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let ids = manifest.providers.map(\.id.rawValue)
        #expect(ids == ["composio.fitbit", "composio.strava", "device.calendar"])
    }

    @Test("unavailable provider still appears with available=false")
    func unavailableSurfaces() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let provider = StubProvider(
            id: appleCalendar,
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read],
            linkedByUserValue: false,
            availableValue: false
        )
        await registry.register(provider)
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let manifest = await CapabilityManifestBuilder().build(
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        )
        let entry = try? #require(manifest.providers.first)
        #expect(entry?.available == false)
        #expect(entry?.linked == false)
    }
}
