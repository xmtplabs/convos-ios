import Combine
import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

/// The announcer is a thin resolver in front of the card path's grant
/// writer; what these tests pin is that a landed per-chat toggle produces
/// the exact writer effects a capability-card approval does — the grant
/// (with the picked bundles), the backend consent record it implies, and
/// the granted/revoked transcript event — and nothing at all when the
/// grant cannot land.
@Suite("AbilityGrantAnnouncer Tests")
struct AbilityGrantAnnouncerTests {
    private static let conversationId = "conv-1"
    private static let agentInboxId = "agent-1"

    private static func connection(id: String = "conn-a", connectedAt: Date = Date(timeIntervalSince1970: 0)) -> CloudConnection {
        CloudConnection(
            id: id,
            serviceId: "googlecalendar",
            serviceName: "Google Calendar",
            provider: .composio,
            composioEntityId: "entity-a",
            composioConnectionId: "cconn-a",
            status: .active,
            connectedAt: connectedAt
        )
    }

    private static func recordedGrant(
        connectionId: String = "conn-a",
        bundleIds: [String]? = nil
    ) -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: "googlecalendar",
            grantedToInboxId: agentInboxId,
            grantedAt: Date(timeIntervalSince1970: 0),
            bundleIds: bundleIds
        )
    }

    private struct Env {
        let repository: StubRepository
        let grantWriter: RecordingGrantWriter
        let eventWriter: RecordingEventWriter
        let refreshes: RefreshCounter
        let announcer: CloudAbilityGrantAnnouncer
    }

    private static func makeEnv(onRefresh: (@Sendable (StubRepository) async -> Void)? = nil) -> Env {
        let repository = StubRepository()
        let grantWriter = RecordingGrantWriter()
        let eventWriter = RecordingEventWriter()
        let refreshes = RefreshCounter()
        let announcer = CloudAbilityGrantAnnouncer(
            repository: repository,
            grantWriter: { grantWriter },
            eventWriter: { eventWriter },
            refreshConnections: {
                await refreshes.increment()
                await onRefresh?(repository)
            }
        )
        return Env(
            repository: repository,
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            refreshes: refreshes,
            announcer: announcer
        )
    }

    @Test("A landed enable grants through the card path and broadcasts granted")
    func enableGrantsAndBroadcasts() async throws {
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let refreshCount = await env.refreshes.count()
        #expect(refreshCount == 0, "an already-hydrated store needs no refresh")
        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.count == 1)
        #expect(grants.first?.connectionId == "conn-a")
        #expect(grants.first?.conversationId == Self.conversationId)
        #expect(grants.first?.bundleIds == ["calendar.events"])
        let events = await env.eventWriter.grantedEvents()
        #expect(events.count == 1)
        #expect(events.first?.providerId == "composio.googlecalendar")
        #expect(events.first?.grantedToInboxId == Self.agentInboxId)
    }

    @Test("A refresh retry resolves a just-connected ability")
    func refreshRetryResolves() async throws {
        // The V2 abilities OAuth just finished: the backend lists the
        // connection, the local store hasn't seen it yet. The (delta,
        // cascade-safe) refresh is what hydrates it.
        let env = Self.makeEnv(onRefresh: { repository in
            await repository.setConnections([Self.connection()])
        })

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let refreshCount = await env.refreshes.count()
        #expect(refreshCount == 1)
        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.count == 1)
    }

    @Test("A missing connection skips without granting or broadcasting")
    func missingConnectionSkips() async throws {
        let env = Self.makeEnv()

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let refreshCount = await env.refreshes.count()
        #expect(refreshCount == 1)
        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.isEmpty, "nothing to grant against")
        let events = await env.eventWriter.grantedEvents()
        #expect(events.isEmpty, "no transcript line for a grant that never landed")
    }

    @Test("An already-recorded grant with the same scope announces nothing")
    func sameScopeIsIdempotent() async throws {
        // Mirrors AgentBuilderConnectionGrantReplayer's repository-based
        // idempotency: no duplicate backend push, no duplicate transcript
        // line for a scope the card path (or an earlier toggle) already
        // announced. Order-insensitive: the same set is the same scope.
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])
        await env.repository.setGrants(
            [Self.recordedGrant(bundleIds: ["calendar.freebusy", "calendar.events"])]
        )

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events", "calendar.freebusy"]
        )

        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.isEmpty)
        let events = await env.eventWriter.grantedEvents()
        #expect(events.isEmpty)
    }

    @Test("Full-service consent over a recorded full-service grant announces nothing")
    func fullServiceOverFullServiceIsIdempotent() async throws {
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])
        await env.repository.setGrants([Self.recordedGrant(bundleIds: nil)])

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: []
        )

        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.isEmpty)
    }

    @Test("A recorded grant with a different scope is re-granted without a transcript line")
    func differentScopeRegrantsSilently() async throws {
        // The legacy entitlement fallback authorizes from the backend
        // consent record; skipping here would let a stale wider scope
        // outlive the member's narrower re-selection. But a scope
        // correction is not a new connection, so no GRANTED event —
        // matching the card path's diff-based broadcasting.
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])
        await env.repository.setGrants([Self.recordedGrant(bundleIds: ["calendar.events", "calendar.freebusy"])])

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.count == 1)
        #expect(grants.first?.bundleIds == ["calendar.events"])
        let events = await env.eventWriter.grantedEvents()
        #expect(events.isEmpty, "a scope correction is not a new connection")
    }

    @Test("A legacy full-service record compared against an explicit selection re-grants")
    func legacyNilScopeVersusExplicitRegrants() async throws {
        // Nil-vs-explicit cannot be compared locally (nil materializes
        // from the live catalog inside the writer), so the conservative
        // direction is to re-push the explicit scope.
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])
        await env.repository.setGrants([Self.recordedGrant(bundleIds: nil)])

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.count == 1)
        #expect(grants.first?.bundleIds == ["calendar.events"])
        let events = await env.eventWriter.grantedEvents()
        #expect(events.isEmpty)
    }

    @Test("An empty bundle selection becomes full-service consent, not an empty scope")
    func emptyBundlesBecomeNil() async throws {
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: []
        )

        let grants = await env.grantWriter.grantedCalls()
        #expect(grants.first?.bundleIds == nil, "the writer fails closed on an empty explicit selection")
    }

    @Test("A failed grant writes no transcript line and does not throw")
    func failedGrantBroadcastsNothing() async throws {
        let env = Self.makeEnv()
        await env.repository.setConnections([Self.connection()])
        await env.grantWriter.setShouldThrow(true)

        await env.announcer.announceEnabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar",
            bundleIds: ["calendar.events"]
        )

        let events = await env.eventWriter.grantedEvents()
        #expect(events.isEmpty)
    }

    @Test("A landed disable revokes the recorded grants and broadcasts revoked")
    func disableRevokesAndBroadcasts() async throws {
        let env = Self.makeEnv()
        await env.repository.setGrants([Self.recordedGrant()])

        await env.announcer.announceDisabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar"
        )

        let revokes = await env.grantWriter.revokedCalls()
        #expect(revokes.count == 1)
        #expect(revokes.first?.connectionId == "conn-a")
        let events = await env.eventWriter.revokedEvents()
        #expect(events.count == 1)
        #expect(events.first?.providerId == "composio.googlecalendar")
        #expect(events.first?.grantedToInboxId == Self.agentInboxId)
    }

    @Test("A disable with nothing recorded is a silent no-op")
    func disableWithNothingRecordedIsNoOp() async throws {
        // A toggle that was never announced (written before announcements
        // existed) has no rows; the withdraw must not manufacture a revoke
        // or put a "removed" line in the transcript over a no-op.
        let env = Self.makeEnv()

        await env.announcer.announceDisabled(
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId,
            abilityId: "googlecalendar"
        )

        let revokes = await env.grantWriter.revokedCalls()
        #expect(revokes.isEmpty)
        let events = await env.eventWriter.revokedEvents()
        #expect(events.isEmpty)
    }
}

// MARK: - Mocks

private actor StubRepository: CloudConnectionRepositoryProtocol {
    private var storedConnections: [CloudConnection] = []
    private var storedGrants: [CloudConnectionGrant] = []

    func setConnections(_ connections: [CloudConnection]) {
        storedConnections = connections
    }

    func setGrants(_ grants: [CloudConnectionGrant]) {
        storedGrants = grants
    }

    func connections() async throws -> [CloudConnection] {
        storedConnections
    }

    nonisolated func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        Just([]).eraseToAnyPublisher()
    }

    func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        storedGrants.filter { $0.conversationId == conversationId }
    }

    nonisolated func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        Just([]).eraseToAnyPublisher()
    }
}

private actor RecordingGrantWriter: CloudConnectionGrantWriterProtocol {
    struct GrantCall: Sendable, Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
        let bundleIds: [String]?
    }

    struct RevokeCall: Sendable, Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
    }

    private var grants: [GrantCall] = []
    private var revokes: [RevokeCall] = []
    private var shouldThrow: Bool = false

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func grantedCalls() -> [GrantCall] { grants }
    func revokedCalls() -> [RevokeCall] { revokes }

    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        if shouldThrow { throw StubError.pushFailed }
        grants.append(
            GrantCall(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId,
                bundleIds: bundleIds
            )
        )
    }

    func grantConnectionConfirmingBackend(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        try await grantConnection(connectionId, to: conversationId, grantedToInboxId: grantedToInboxId, bundleIds: bundleIds)
    }

    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws {
        if shouldThrow { throw StubError.pushFailed }
        revokes.append(
            RevokeCall(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId
            )
        )
    }

    enum StubError: Error {
        case pushFailed
    }
}

private actor RecordingEventWriter: ConnectionEventWriterProtocol {
    struct Call: Sendable {
        let providerId: String
        let grantedToInboxId: String?
        let conversationId: String
    }

    private var grants: [Call] = []
    private var revocations: [Call] = []

    func grantedEvents() -> [Call] { grants }
    func revokedEvents() -> [Call] { revocations }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        grants.append(Call(providerId: providerId, grantedToInboxId: grantedToInboxId, conversationId: conversationId))
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        revocations.append(Call(providerId: providerId, grantedToInboxId: grantedToInboxId, conversationId: conversationId))
    }
}

private actor RefreshCounter {
    private var value: Int = 0

    func increment() {
        value += 1
    }

    func count() -> Int {
        value
    }
}
