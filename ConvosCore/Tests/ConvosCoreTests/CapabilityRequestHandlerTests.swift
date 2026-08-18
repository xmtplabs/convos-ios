import ConvosConnections
@testable import ConvosCore
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
    private let handler: CapabilityRequestHandler = CapabilityRequestHandler()
    private let conversationId: String = "conv-1"

    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.googlecalendar")
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
        preferredProviders: [ProviderID]? = nil,
        askerInboxId: String = "agent-1"
    ) -> CapabilityRequest {
        CapabilityRequest(
            requestId: "req-1",
            askerInboxId: askerInboxId,
            subject: subject,
            capability: capability,
            rationale: "test",
            preferredProviders: preferredProviders
        )
    }

    @Test("zero linked providers → connectAndApprove")
    func variant3() async throws {
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
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .connectAndApprove)
        #expect(layout.defaultSelection.isEmpty)
    }

    @Test("exactly one linked provider → confirm with that provider preselected")
    func variant1() async throws {
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
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .confirm)
        #expect(layout.defaultSelection == [appleCalendar])
    }

    @Test("multiple linked providers on non-federating subject → singleSelect")
    func variant2aNonFederating() async throws {
        let registry = await makeRegistry([
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(subject: .calendar, capability: .read),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .singleSelect)
        #expect(layout.defaultSelection.isEmpty)
    }

    @Test("multiple linked providers on federating subject + read → multiSelect")
    func variant2bFederatingRead() async throws {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(subject: .fitness, capability: .read),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .multiSelect)
    }

    @Test("multiple linked providers on federating subject + write → singleSelect")
    func variant2aFederatingWrite() async throws {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read, .writeCreate], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read, .writeCreate], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(subject: .fitness, capability: .writeCreate),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .singleSelect, "writes never federate, even on .fitness")
    }
}

@Suite("CapabilityRequestHandler.computeLayout — requested providers")
struct ComputeLayoutPreferredProvidersTests {
    private let handler: CapabilityRequestHandler = CapabilityRequestHandler()
    private let conversationId: String = "conv-1"
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.googlecalendar")
    private let outlook: ProviderID = ProviderID(rawValue: "composio.microsoftoutlook")
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")

    private func makeRegistry(_ providers: [StubProvider]) async -> any CapabilityProviderRegistry {
        let registry = InMemoryCapabilityProviderRegistry()
        for provider in providers { await registry.register(provider) }
        return registry
    }

    private func request(
        subject: CapabilitySubject = .calendar,
        capability: ConnectionCapability = .read,
        preferredProviders: [ProviderID]?
    ) -> CapabilityRequest {
        CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
            subject: subject,
            capability: capability,
            rationale: "test",
            preferredProviders: preferredProviders
        )
    }

    @Test("a named provider that is linked is the one confirmed, not a linked sibling")
    func namedLinkedProviderWins() async throws {
        let registry = await makeRegistry([
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(preferredProviders: [googleCalendar]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        // Both are linked, but only the named one may be offered — a card row for
        // Apple Calendar would let the user grant a provider the agent never asked
        // for and cannot exec against.
        let offered: [ProviderID] = layout.providers.map(\.id)
        #expect(offered == [googleCalendar])
        #expect(layout.variant == .confirm)
        #expect(layout.defaultSelection == [googleCalendar])
    }

    @Test("a named provider that is not linked yet is the one offered to connect")
    func namedUnlinkedProviderIsOffered() async throws {
        let registry = await makeRegistry([
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: false),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(preferredProviders: [googleCalendar]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        // The user having some other calendar linked is not consent to use it: the
        // card offers to connect the calendar the agent actually named.
        let offered: [ProviderID] = layout.providers.map(\.id)
        #expect(layout.variant == .connectAndApprove)
        #expect(offered == [googleCalendar])
    }

    @Test("a request naming only unknown providers yields no card at all")
    func unknownProviderYieldsNoLayout() async {
        let registry = await makeRegistry([
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: request(preferredProviders: [ProviderID(rawValue: "composio.someothercalendar")]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        // Substituting Google Calendar here would offer the user a service the agent
        // never asked about and write a grant it cannot use.
        #expect(layout == nil)
    }

    @Test("one known provider among unknown ones still resolves to the known one")
    func partiallyKnownRequestResolvesToKnown() async throws {
        let registry = await makeRegistry([
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(preferredProviders: [ProviderID(rawValue: "composio.someothercalendar"), googleCalendar]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        let offered: [ProviderID] = layout.providers.map(\.id)
        #expect(offered == [googleCalendar])
        #expect(layout.defaultSelection == [googleCalendar])
    }

    @Test("no named providers keeps the single registered provider on the card")
    func noPreferenceKeepsSingleProviderBehaviour() async throws {
        let registry = await makeRegistry([
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(preferredProviders: nil),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        let offered: [ProviderID] = layout.providers.map(\.id)
        #expect(layout.variant == .confirm)
        #expect(offered == [googleCalendar])
        #expect(layout.defaultSelection == [googleCalendar])
    }

    @Test("no named providers still offers every provider registered for the subject")
    func noPreferenceKeepsEveryProvider() async throws {
        let registry = await makeRegistry([
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: outlook, subject: .calendar, displayName: "Microsoft Outlook", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(preferredProviders: nil),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        let offered: Set<ProviderID> = Set(layout.providers.map(\.id))
        #expect(layout.variant == .singleSelect)
        #expect(offered == [appleCalendar, outlook])
    }

    @Test("a federating read keeps every named provider selected")
    func multiSelectHonorsEveryNamedProvider() async throws {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read], linkedByUserValue: true),
            StubProvider(id: fitbit, subject: .fitness, displayName: "Fitbit", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: request(subject: .fitness, preferredProviders: [strava, fitbit]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .multiSelect)
        #expect(layout.defaultSelection == [strava, fitbit])
    }

    @Test("a request whose named provider cannot do the verb yields no card")
    func namedProviderMissingVerbYieldsNoLayout() async {
        let registry = await makeRegistry([
            StubProvider(id: strava, subject: .fitness, displayName: "Strava", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: request(subject: .fitness, capability: .writeCreate, preferredProviders: [strava]),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout == nil)
    }

    @Test("a subject with nothing registered yields no card")
    func unregisteredSubjectYieldsNoLayout() async {
        let registry = await makeRegistry([
            StubProvider(id: googleCalendar, subject: .calendar, displayName: "Google Calendar", capabilities: [.read], linkedByUserValue: true),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = await handler.computeLayout(
            request: request(subject: .mail, preferredProviders: nil),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        )
        #expect(layout == nil)
    }
}

@Suite("CapabilityRequestHandler.computeLayout — verb-consent shortcut")
struct ComputeLayoutVerbConsentTests {
    private let handler: CapabilityRequestHandler = CapabilityRequestHandler()
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
            conversationId: conversationId,
            grantedToInboxId: "agent-1"
        )

        let layout = try #require(await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                askerInboxId: "agent-1",
                subject: .calendar,
                capability: .writeCreate,
                rationale: "Add an event"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
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
            conversationId: conversationId,
            grantedToInboxId: "agent-1"
        )

        let layout = try #require(await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                askerInboxId: "agent-1",
                subject: .fitness,
                capability: .writeCreate,
                rationale: "Log a workout"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
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
            conversationId: conversationId,
            grantedToInboxId: "agent-1"
        )

        let layout = try #require(await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                askerInboxId: "agent-1",
                subject: .calendar,
                capability: .read,
                rationale: "test"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        // Same-verb resolution → not the verb-consent path; falls through to confirm.
        #expect(layout.variant == .confirm)
    }

    @Test("no shortcut when no other verb has a resolution")
    func noOtherVerbResolved() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        await registry.register(
            StubProvider(id: appleCalendar, subject: .calendar, displayName: "Apple Calendar", capabilities: [.read], linkedByUserValue: true)
        )
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: CapabilityRequest(
                requestId: "req-1",
                askerInboxId: "agent-1",
                subject: .calendar,
                capability: .read,
                rationale: "test"
            ),
            registry: registry,
            resolver: resolver,
            conversationId: conversationId
        ))
        #expect(layout.variant == .confirm)
    }
}

@Suite("CapabilityRequestHandler.commit / deny / cancel")
struct CommitDenyCancelTests {
    private let handler: CapabilityRequestHandler = CapabilityRequestHandler()
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")

    @Test("commit persists resolution and returns approved result")
    func commitPersists() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
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

        let stored = await resolver.resolution(
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: "agent-1"
        )
        #expect(stored == [appleCalendar])
    }

    @Test("commit rejects an inconsistent set without persisting")
    func commitValidates() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        await #expect(throws: CapabilityResolutionError.self) {
            try await handler.commit(
                request: request,
                approvedProviderIds: [appleCalendar, ProviderID(rawValue: "composio.googlecalendar")],
                resolver: resolver,
                conversationId: "conv-1"
            )
        }
        let stored = await resolver.resolution(
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: "agent-1"
        )
        #expect(stored.isEmpty, "rejected commit must not persist anything")
    }

    @Test("deny returns denied result with no providers and no resolver mutation")
    func denyDoesNothing() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let request = CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        let result = handler.deny(request: request)
        #expect(result.status == .denied)
        #expect(result.providers.isEmpty)
        let stored = await resolver.resolution(
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: "agent-1"
        )
        #expect(stored.isEmpty)
    }

    @Test("cancel returns cancelled result with no providers")
    func cancelMatchesShape() {
        let request = CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
        let result = CapabilityRequestHandler().cancel(request: request)
        #expect(result.status == .cancelled)
        #expect(result.providers.isEmpty)
    }
}

@Suite("CapabilityRequestHandler.computeLayout — service bundles")
struct ComputeLayoutServiceBundlesTests {
    private let handler: CapabilityRequestHandler = CapabilityRequestHandler()
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.googlecalendar")
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")

    private func makeRequest() -> CapabilityRequest {
        CapabilityRequest(
            requestId: "req-1",
            askerInboxId: "agent-1",
            subject: .calendar,
            capability: .read,
            rationale: "test"
        )
    }

    private func makeRegistry(_ providers: [StubProvider]) async -> any CapabilityProviderRegistry {
        let registry = InMemoryCapabilityProviderRegistry()
        for provider in providers { await registry.register(provider) }
        return registry
    }

    private func calendarService(version: Int = 2) -> CloudConnectionsAPI.ServiceConfig {
        CloudConnectionsAPI.ServiceConfig(
            id: "googlecalendar",
            composioSlug: "googlecalendar",
            version: version,
            displayName: .init(values: ["en": "Google Calendar"]),
            bundles: [
                .init(
                    id: "calendar.events",
                    title: .init(values: ["en": "Events"]),
                    description: .init(values: ["en": "View and edit events on all calendars"]),
                    defaultEnabled: false
                ),
                .init(
                    id: "calendar.events.read",
                    title: .init(values: ["en": "View events"]),
                    description: .init(values: ["en": "View events on all calendars"]),
                    defaultEnabled: true
                ),
            ]
        )
    }

    @Test("cloud providers with a catalog entry get bundle rows; device providers don't")
    func bundlesAttachToCloudProviders() async throws {
        let registry = await makeRegistry([
            StubProvider(
                id: googleCalendar,
                subject: .calendar,
                displayName: "Google Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
            StubProvider(
                id: appleCalendar,
                subject: .calendar,
                displayName: "Apple Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1",
            services: [calendarService()]
        ))
        #expect(layout.serviceBundles.count == 1)
        let group = layout.serviceBundles.first
        #expect(group?.providerId == googleCalendar)
        #expect(group?.serviceId == "googlecalendar")
        #expect(group?.serviceVersion == 2)
        #expect(group?.rows.map(\.id) == ["calendar.events", "calendar.events.read"])
        #expect(group?.rows.first?.title == "Events")
        #expect(group?.rows.first?.description == "View and edit events on all calendars")
    }

    @Test("bundle rows carry the catalog's defaultEnabled flags")
    func rowsCarryDefaultEnabledFlags() async throws {
        let registry = await makeRegistry([
            StubProvider(
                id: googleCalendar,
                subject: .calendar,
                displayName: "Google Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1",
            services: [calendarService()]
        ))
        let rows = layout.serviceBundles.first?.rows ?? []
        #expect(rows.map(\.id) == ["calendar.events", "calendar.events.read"])
        #expect(rows.map(\.defaultEnabled) == [false, true])
    }

    @Test("an empty catalog leaves the layout bundle-free")
    func emptyCatalogMeansNoBundles() async throws {
        let registry = await makeRegistry([
            StubProvider(
                id: googleCalendar,
                subject: .calendar,
                displayName: "Google Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let layout = try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1"
        ))
        #expect(layout.serviceBundles.isEmpty)
    }

    // MARK: - Existing-grant stamping (Done-as-revoke seeding)

    private func makeGrant(
        conversationId: String = "conv-1",
        grantedToInboxId: String = "agent-1",
        bundleIds: [String]?
    ) -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: "conn-1",
            conversationId: conversationId,
            serviceId: "googlecalendar",
            grantedToInboxId: grantedToInboxId,
            grantedAt: Date(timeIntervalSince1970: 0),
            bundleIds: bundleIds
        )
    }

    private func computeLayout(existingGrants: [CloudConnectionGrant]) async throws -> CapabilityPickerLayout {
        let registry = await makeRegistry([
            StubProvider(
                id: googleCalendar,
                subject: .calendar,
                displayName: "Google Calendar",
                capabilities: [.read],
                linkedByUserValue: true
            ),
        ])
        let resolver = InMemoryCapabilityResolver(registry: registry)
        return try #require(await handler.computeLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            conversationId: "conv-1",
            services: [calendarService()],
            existingGrants: existingGrants
        ))
    }

    @Test("the asking agent's grant stamps its bundle ids onto the group")
    func existingGrantStampsBundleIds() async throws {
        let layout = try await computeLayout(existingGrants: [makeGrant(bundleIds: ["calendar.events"])])
        #expect(layout.serviceBundles.first?.grantedBundleIds == ["calendar.events"])
    }

    @Test("a whole-toolkit grant (nil bundleIds) materializes as every catalog row")
    func wholeToolkitGrantCoversEveryRow() async throws {
        let layout = try await computeLayout(existingGrants: [makeGrant(bundleIds: nil)])
        #expect(layout.serviceBundles.first?.grantedBundleIds == ["calendar.events", "calendar.events.read"])
    }

    @Test("no grant leaves grantedBundleIds nil")
    func noGrantLeavesNil() async throws {
        let layout = try await computeLayout(existingGrants: [])
        #expect(layout.serviceBundles.count == 1)
        #expect(layout.serviceBundles.first?.grantedBundleIds == nil)
    }

    @Test("another agent's grant must not seed this agent's sheet")
    func otherAgentsGrantIsIgnored() async throws {
        let layout = try await computeLayout(
            existingGrants: [makeGrant(grantedToInboxId: "agent-2", bundleIds: ["calendar.events"])]
        )
        #expect(layout.serviceBundles.first?.grantedBundleIds == nil)
    }

    @Test("another conversation's grant must not seed this sheet")
    func otherConversationsGrantIsIgnored() async throws {
        let layout = try await computeLayout(
            existingGrants: [makeGrant(conversationId: "conv-2", bundleIds: ["calendar.events"])]
        )
        #expect(layout.serviceBundles.first?.grantedBundleIds == nil)
    }
}
