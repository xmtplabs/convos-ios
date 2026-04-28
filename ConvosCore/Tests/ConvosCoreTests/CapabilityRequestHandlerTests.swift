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

    var linkedByUser: Bool { get async { linkedByUserValue } }
    var available: Bool { get async { true } }
}

@Suite("CapabilityRequestHandler.computeLayout — variant selection")
struct ComputeLayoutVariantTests {
    private let handler = CapabilityRequestHandler()
    private let conversationId: String = "conv-1"

    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.google_calendar")
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")

    private func makeRegistry(_ providers: [StubProvider]) async -> any CapabilityProviderRegistry {
        let registry = InMemoryCapabilityProviderRegistry()
        for provider in providers { await registry.register(provider) }
        return registry
    }

    private func makeRequest(
        subject: CapabilitySubject = .calendar,
        capability: ConnectionCapability = .read,
        preferredProviders: [ProviderID]? = nil
    ) -> CapabilityRequest {
        CapabilityRequest(
            requestId: "req-1",
            subject: subject,
            capability: capability,
            rationale: "test",
            preferredProviders: preferredProviders
        )
    }

    @Test("zero linked providers → connectAndApprove")
    func variant3() async {
        let registry = await makeRegistry([
            StubProvider(
                id: appleCalendar,
                subject: .calendar,
                displayName: "Apple Calendar",
                capabilities: [.read],
                linkedByUserValue: false
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .connectAndApprove)
        #expect(layout.defaultSelection.isEmpty)
    }

    @Test("exactly one linked provider → confirm with that provider preselected")
    func variant1() async {
        let registry = await makeRegistry([
            StubProvider(
                id: appleCalendar,
                subject: .calendar,
                displayName: "Apple Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .confirm)
        #expect(layout.defaultSelection == [appleCalendar])
    }

    @Test("multiple linked providers on non-federating subject → singleSelect")
    func variant2aNonFederating() async {
        let registry = await makeRegistry([
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: makeRequest(subject: .calendar, capability: .read),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .singleSelect)
        #expect(layout.defaultSelection.isEmpty)
    }

    @Test("multiple linked providers on federating subject + read → multiSelect")
    func variant2bFederatingRead() async {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: makeRequest(subject: .fitness, capability: .read),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .multiSelect)
    }

    @Test("multiple linked providers on federating subject + write → singleSelect")
    func variant2aFederatingWrite() async {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read, .writeCreate], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read, .writeCreate], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: makeRequest(subject: .fitness, capability: .writeCreate),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .singleSelect, "writes never federate, even on .fitness")
    }
}

@Suite("CapabilityRequestHandler.computeLayout — preferredProviders hint")
struct ComputeLayoutPreferredProvidersTests {
    private let handler = CapabilityRequestHandler()
    private let conversationId: String = "conv-1"
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.google_calendar")
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")

    @Test("singleSelect picker honors first satisfiable preferredProvider")
    func singleSelectHonorsHint() async {
        let registry = InMemoryCapabilityProviderRegistry()
        for stub in [
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ] {
            await registry.register(stub)
        }
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .calendar,
                capability: .read,
                rationale: "test",
                preferredProviders: [googleCalendar]
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .singleSelect)
        #expect(layout.defaultSelection == [googleCalendar])
    }

    @Test("multiSelect picker honors all satisfiable preferredProviders")
    func multiSelectHonorsHint() async {
        let registry = InMemoryCapabilityProviderRegistry()
        for stub in [
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read], linkedByUserValue: true),
        ] {
            await registry.register(stub)
        }
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .fitness,
                capability: .read,
                rationale: "test",
                preferredProviders: [strava, fitbit]
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .multiSelect)
        #expect(layout.defaultSelection == [strava, fitbit])
    }

    @Test("hint that points at unlinked providers is dropped")
    func hintFallsBackOnUnlinked() async {
        let registry = InMemoryCapabilityProviderRegistry()
        for stub in [
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: false),
        ] {
            await registry.register(stub)
        }
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .calendar,
                capability: .read,
                rationale: "test",
                preferredProviders: [googleCalendar]
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        // Only one linked provider → variant 1 (confirm), default selection is the
        // single linked option, not the unlinked Google Calendar that the agent asked for.
        #expect(layout.variant == .confirm)
        #expect(layout.defaultSelection == [appleCalendar])
    }
}

@Suite("CapabilityRequestHandler.computeLayout — verb-consent shortcut")
struct ComputeLayoutVerbConsentTests {
    private let handler = CapabilityRequestHandler()
    private let conversationId: String = "conv-1"
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")

    @Test("existing read resolution defaults a writeCreate request to verbConsent")
    func writeAfterReadShortsToVerbConsent() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        await registry.register(
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read, .writeCreate], linkedByUserValue: true)
        )
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: conversationId
        )

        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .calendar,
                capability: .writeCreate,
                rationale: "Add an event"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .verbConsent)
        #expect(layout.defaultSelection == [appleCalendar])
    }

    @Test("federated read on .fitness → write request defaults to single provider")
    func federatedReadToWrite() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        for stub in [
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read, .writeCreate], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read, .writeCreate], linkedByUserValue: true),
        ] {
            await registry.register(stub)
        }
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [strava, fitbit],
            subject: .fitness,
            capability: .read,
            conversationId: conversationId
        )

        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .fitness,
                capability: .writeCreate,
                rationale: "Log a workout"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .verbConsent)
        // Writes never federate; default to the single deterministic pick.
        #expect(layout.defaultSelection.count == 1)
        #expect(layout.defaultSelection.contains(fitbit) || layout.defaultSelection.contains(strava))
    }

    @Test("no shortcut when the requested verb already has a resolution")
    func sameVerbResolvedFallsThrough() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        await registry.register(
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true)
        )
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: conversationId
        )

        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .calendar,
                capability: .read,
                rationale: "test"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        // Same-verb resolution → not the verb-consent path; falls through to confirm.
        #expect(layout.variant == .confirm)
    }

    @Test("no shortcut when no other verb has a resolution")
    func noOtherVerbResolved() async {
        let registry = InMemoryCapabilityProviderRegistry()
        await registry.register(
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true)
        )
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                subject: .calendar,
                capability: .read,
                rationale: "test"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout.variant == .confirm)
    }
}

@Suite("CapabilityRequestHandler.commit / deny / cancel")
struct CommitDenyCancelTests {
    private let handler = CapabilityRequestHandler()
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")

    @Test("commit persists resolution and returns approved result")
    func commitPersists() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        let result = try await handler.commit(
            request: request,
            approvedProviderIds: [appleCalendar],
            resolver: resolver,
            conversationId: "conv-1"
        )
        #expect(result.status == .approved)
        #expect(result.providers == [appleCalendar])

        let stored = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(stored == [appleCalendar])
    }

    @Test("commit rejects an inconsistent set without persisting")
    func commitValidates() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        await #expect(throws: CapabilityResolutionError.self) {
            try await handler.commit(
                request: request,
                approvedProviderIds: [appleCalendar, ProviderID(rawValue: "composio.google_calendar")],
                resolver: resolver,
                conversationId: "conv-1"
            )
        }
        let stored = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(stored.isEmpty, "rejected commit must not persist anything")
    }

    @Test("deny returns denied result with no providers and no resolver mutation")
    func denyDoesNothing() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        let result = handler.deny(request: request)
        #expect(result.status == .denied)
        #expect(result.providers.isEmpty)
        let stored = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(stored.isEmpty)
    }

    @Test("cancel returns cancelled result with no providers")
    func cancelMatchesShape() {
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        let result = CapabilityRequestHandler().cancel(request: request)
        #expect(result.status == .cancelled)
        #expect(result.providers.isEmpty)
    }
}
