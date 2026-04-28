@testable import ConvosCore
import ConvosConnections
import Foundation
import Testing

@Suite("CapabilitySubject federation flag")
struct CapabilitySubjectFederationTests {
    @Test("fitness opts in to read federation")
    func fitnessFederates() {
        #expect(CapabilitySubject.fitness.allowsReadFederation == true)
    }

    @Test("calendar does not federate")
    func calendarDoesNotFederate() {
        #expect(CapabilitySubject.calendar.allowsReadFederation == false)
    }

    @Test("all non-fitness subjects default to false")
    func conservativeDefault() {
        for subject in CapabilitySubject.allCases where subject != .fitness {
            #expect(subject.allowsReadFederation == false, "\(subject) should default to false")
        }
    }
}

@Suite("CapabilityResolutionValidator")
struct CapabilityResolutionValidatorTests {
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.google_calendar")

    @Test("empty set is rejected")
    func emptySetRejected() {
        #expect(throws: CapabilityResolutionError.self) {
            try CapabilityResolutionValidator.validate(
                providerIds: [],
                subject: .calendar,
                capability: .read
            )
        }
    }

    @Test("single provider is always valid")
    func singleProviderAlwaysValid() throws {
        for subject in CapabilitySubject.allCases {
            for capability in ConnectionCapability.allCases {
                try CapabilityResolutionValidator.validate(
                    providerIds: [strava],
                    subject: subject,
                    capability: capability
                )
            }
        }
    }

    @Test("federated read on fitness is valid")
    func fitnessReadFederationValid() throws {
        try CapabilityResolutionValidator.validate(
            providerIds: [strava, fitbit],
            subject: .fitness,
            capability: .read
        )
    }

    @Test("federated read on calendar is rejected")
    func calendarReadFederationRejected() {
        #expect(throws: CapabilityResolutionError.self) {
            try CapabilityResolutionValidator.validate(
                providerIds: [appleCalendar, googleCalendar],
                subject: .calendar,
                capability: .read
            )
        }
    }

    @Test("federated write is rejected even on federating subjects")
    func writesNeverFederate() {
        for verb in [ConnectionCapability.writeCreate, .writeUpdate, .writeDelete] {
            #expect(throws: CapabilityResolutionError.self, "\(verb) on .fitness should fail with multi-provider set") {
                try CapabilityResolutionValidator.validate(
                    providerIds: [strava, fitbit],
                    subject: .fitness,
                    capability: verb
                )
            }
        }
    }
}

@Suite("InMemoryCapabilityProviderRegistry")
struct InMemoryCapabilityProviderRegistryTests {
    private struct StubProvider: CapabilityProvider {
        let id: ProviderID
        let subject: CapabilitySubject
        let displayName: String
        let iconName: String = ""
        let capabilities: Set<ConnectionCapability>
        let linkedByUserValue: Bool
        var linkedByUser: Bool {
            get async { linkedByUserValue }
        }
    }

    @Test("register, lookup, unregister")
    func registerAndUnregister() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let strava = StubProvider(
            id: ProviderID(rawValue: "composio.strava"),
            subject: .fitness,
            displayName: "Strava",
            capabilities: [.read],
            linkedByUserValue: true
        )

        await registry.register(strava)
        let found = await registry.providers(for: .fitness)
        #expect(found.count == 1)
        #expect(found[0].id == strava.id)

        await registry.unregister(id: strava.id)
        let afterRemove = await registry.providers(for: .fitness)
        #expect(afterRemove.isEmpty)
    }

    @Test("providers returned sorted by id for stable picker rendering")
    func sortedById() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let fitbit = StubProvider(
            id: ProviderID(rawValue: "composio.fitbit"),
            subject: .fitness,
            displayName: "Fitbit",
            capabilities: [.read],
            linkedByUserValue: true
        )
        let strava = StubProvider(
            id: ProviderID(rawValue: "composio.strava"),
            subject: .fitness,
            displayName: "Strava",
            capabilities: [.read],
            linkedByUserValue: true
        )
        await registry.register(strava)
        await registry.register(fitbit)
        let found = await registry.providers(for: .fitness)
        #expect(found.map(\.id.rawValue) == ["composio.fitbit", "composio.strava"])
    }

    @Test("providers filtered by subject")
    func filteredBySubject() async {
        let registry = InMemoryCapabilityProviderRegistry()
        let strava = StubProvider(
            id: ProviderID(rawValue: "composio.strava"),
            subject: .fitness,
            displayName: "Strava",
            capabilities: [.read],
            linkedByUserValue: true
        )
        let appleCalendar = StubProvider(
            id: ProviderID(rawValue: "device.calendar"),
            subject: .calendar,
            displayName: "Apple Calendar",
            capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete],
            linkedByUserValue: true
        )
        await registry.register(strava)
        await registry.register(appleCalendar)

        let fitnessProviders = await registry.providers(for: .fitness)
        #expect(fitnessProviders.map(\.id) == [strava.id])

        let calendarProviders = await registry.providers(for: .calendar)
        #expect(calendarProviders.map(\.id) == [appleCalendar.id])
    }
}

@Suite("InMemoryCapabilityResolver")
struct InMemoryCapabilityResolverTests {
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")
    private let googleCalendar: ProviderID = ProviderID(rawValue: "composio.google_calendar")

    @Test("empty resolution by default")
    func emptyByDefault() async {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "x")
        #expect(result.isEmpty)
    }

    @Test("setResolution then resolution returns it")
    func roundTrip() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "x"
        )
        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "x")
        #expect(result == [appleCalendar])
    }

    @Test("setResolution validates federation rules")
    func validatesOnSet() async {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        await #expect(throws: CapabilityResolutionError.self) {
            try await resolver.setResolution(
                [appleCalendar, googleCalendar],
                subject: .calendar,
                capability: .read,
                conversationId: "x"
            )
        }
    }

    @Test("federated fitness read accepted")
    func federatedFitnessAccepted() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution(
            [strava, fitbit],
            subject: .fitness,
            capability: .read,
            conversationId: "x"
        )
        let result = await resolver.resolution(subject: .fitness, capability: .read, conversationId: "x")
        #expect(result == [strava, fitbit])
    }

    @Test("removeProviderFromAllResolutions shrinks federated sets and clears singletons")
    func removeProvider() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        // Singleton resolution that should be cleared
        try await resolver.setResolution(
            [strava],
            subject: .fitness,
            capability: .writeCreate,
            conversationId: "x"
        )
        // Federated resolution that should shrink to {fitbit}
        try await resolver.setResolution(
            [strava, fitbit],
            subject: .fitness,
            capability: .read,
            conversationId: "x"
        )

        try await resolver.removeProviderFromAllResolutions(strava)

        let writeResult = await resolver.resolution(subject: .fitness, capability: .writeCreate, conversationId: "x")
        #expect(writeResult.isEmpty, "singleton resolution referencing the removed provider should be cleared")

        let readResult = await resolver.resolution(subject: .fitness, capability: .read, conversationId: "x")
        #expect(readResult == [fitbit], "federated resolution should shrink to remaining providers")
    }

    @Test("clearAllResolutions removes every verb for one (subject, conversation)")
    func clearAll() async throws {
        let resolver = InMemoryCapabilityResolver(registry: InMemoryCapabilityProviderRegistry())
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "x")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .writeCreate, conversationId: "x")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "y")

        try await resolver.clearAllResolutions(subject: .calendar, conversationId: "x")

        let xRead = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "x")
        let xWrite = await resolver.resolution(subject: .calendar, capability: .writeCreate, conversationId: "x")
        let yRead = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "y")
        #expect(xRead.isEmpty)
        #expect(xWrite.isEmpty)
        #expect(yRead == [appleCalendar], "other conversation untouched")
    }
}
