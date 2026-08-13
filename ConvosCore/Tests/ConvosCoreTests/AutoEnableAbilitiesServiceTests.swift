import Combine
import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

/// Decision coverage for the auto-enable fan-out that runs when the user
/// adds an agent: which connections qualify, how the typed
/// connection-not-found refusal rolls back, and that the gate turns the
/// whole path into a no-op.
@Suite("AutoEnableAbilitiesService")
struct AutoEnableAbilitiesServiceTests {
    private let conversationId = "convo-1"
    private let agentInboxId = "agent-inbox"

    @Test("disabled gate performs no writes at all")
    func disabledGateDoesNothing() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [makeConnection()],
            grants: [],
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            enabled: false
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.confirmingGrants.isEmpty)
        #expect(grantWriter.revokes.isEmpty)
        #expect(eventWriter.grantedEvents.isEmpty)
    }

    @Test("grants every live supported connection and posts one line per service")
    func grantsLiveSupportedConnections() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [
                makeConnection(id: "conn-cal", serviceId: "googlecalendar"),
                makeConnection(id: "conn-mail", serviceId: "gmail"),
            ],
            grants: [],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.confirmingGrants == [
            SpyGrantWriter.Grant(
                connectionId: "conn-cal",
                conversationId: conversationId,
                grantedToInboxId: agentInboxId,
                bundleIds: nil
            ),
            SpyGrantWriter.Grant(
                connectionId: "conn-mail",
                conversationId: conversationId,
                grantedToInboxId: agentInboxId,
                bundleIds: nil
            ),
        ])
        #expect(grantWriter.revokes.isEmpty)
        #expect(eventWriter.grantedEvents == [
            SpyEventWriter.Event(
                providerId: "composio.googlecalendar",
                grantedToInboxId: agentInboxId,
                conversationId: conversationId
            ),
            SpyEventWriter.Event(
                providerId: "composio.gmail",
                grantedToInboxId: agentInboxId,
                conversationId: conversationId
            ),
        ])
    }

    @Test("unsupported services and non-active connections do not qualify")
    func skipsUnsupportedAndInactive() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [
                makeConnection(id: "conn-notion", serviceId: "notion"),
                makeConnection(id: "conn-expired", serviceId: "googlecalendar", status: .expired),
                makeConnection(id: "conn-revoked", serviceId: "gmail", status: .revoked),
            ],
            grants: [],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.confirmingGrants.isEmpty)
        #expect(eventWriter.grantedEvents.isEmpty)
    }

    @Test("an existing grant for the same agent skips the connection")
    func skipsAlreadyGrantedToSameAgent() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [makeConnection(id: "conn-cal", serviceId: "googlecalendar")],
            grants: [
                makeGrant(connectionId: "conn-cal", conversationId: conversationId, grantedToInboxId: agentInboxId),
            ],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.confirmingGrants.isEmpty)
        #expect(eventWriter.grantedEvents.isEmpty)
    }

    @Test("another agent's grant does not block this agent")
    func grantsWhenOnlyAnotherAgentHoldsTheConnection() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [makeConnection(id: "conn-cal", serviceId: "googlecalendar")],
            grants: [
                makeGrant(connectionId: "conn-cal", conversationId: conversationId, grantedToInboxId: "other-agent"),
            ],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.confirmingGrants.count == 1)
        #expect(grantWriter.confirmingGrants.first?.grantedToInboxId == agentInboxId)
    }

    @Test("a grant for the same tuple in another conversation does not block")
    func qualifyingIgnoresOtherConversationsGrants() {
        let connections = [makeConnection(id: "conn-cal", serviceId: "googlecalendar")]
        let grants = [
            makeGrant(connectionId: "conn-cal", conversationId: "other-convo", grantedToInboxId: agentInboxId),
        ]

        let qualifying = AutoEnableAbilitiesService.qualifyingConnections(
            connections: connections,
            existingGrants: grants,
            conversationId: conversationId,
            agentInboxId: agentInboxId
        )

        #expect(qualifying.map(\.id) == ["conn-cal"])
    }

    @Test("connection-not-found rolls the grant back and posts no line")
    func rollsBackOnConnectionNotFound() async {
        let grantWriter = SpyGrantWriter()
        grantWriter.errorsByConnectionId = ["conn-cal": CloudConnectionsAPI.GrantError.connectionNotFound]
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [
                makeConnection(id: "conn-cal", serviceId: "googlecalendar"),
                makeConnection(id: "conn-mail", serviceId: "gmail"),
            ],
            grants: [],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.revokes == [
            SpyGrantWriter.Revoke(
                connectionId: "conn-cal",
                conversationId: conversationId,
                grantedToInboxId: agentInboxId
            ),
        ])
        #expect(eventWriter.grantedEvents == [
            SpyEventWriter.Event(
                providerId: "composio.gmail",
                grantedToInboxId: agentInboxId,
                conversationId: conversationId
            ),
        ])
    }

    @Test("a transient failure leaves the row alone and posts no line")
    func transientFailureRollsNothingBack() async {
        let grantWriter = SpyGrantWriter()
        grantWriter.errorsByConnectionId = ["conn-cal": SpyGrantWriter.Failure()]
        let eventWriter = SpyEventWriter()
        let service = makeService(
            connections: [
                makeConnection(id: "conn-cal", serviceId: "googlecalendar"),
                makeConnection(id: "conn-mail", serviceId: "gmail"),
            ],
            grants: [],
            grantWriter: grantWriter,
            eventWriter: eventWriter
        )

        await service.autoEnable(conversationId: conversationId, agentInboxId: agentInboxId)

        #expect(grantWriter.revokes.isEmpty)
        #expect(eventWriter.grantedEvents == [
            SpyEventWriter.Event(
                providerId: "composio.gmail",
                grantedToInboxId: agentInboxId,
                conversationId: conversationId
            ),
        ])
    }

    // MARK: - Fixtures

    private func makeService(
        connections: [CloudConnection],
        grants: [CloudConnectionGrant],
        grantWriter: SpyGrantWriter,
        eventWriter: SpyEventWriter,
        enabled: Bool = true
    ) -> AutoEnableAbilitiesService {
        AutoEnableAbilitiesService(
            cloudConnectionRepository: StubConnectionsRepository(
                stubbedConnections: connections,
                stubbedGrants: grants
            ),
            grantWriter: grantWriter,
            connectionEventWriter: eventWriter,
            isEnabled: { enabled }
        )
    }

    private func makeConnection(
        id: String = "conn-1",
        serviceId: String = "googlecalendar",
        status: CloudConnectionStatus = .active
    ) -> CloudConnection {
        CloudConnection(
            id: id,
            serviceId: serviceId,
            serviceName: serviceId,
            provider: .composio,
            composioEntityId: "entity-1",
            composioConnectionId: "composio-1",
            status: status,
            connectedAt: Date()
        )
    }

    private func makeGrant(
        connectionId: String,
        conversationId: String,
        grantedToInboxId: String
    ) -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: "googlecalendar",
            grantedToInboxId: grantedToInboxId,
            grantedAt: Date()
        )
    }
}

// MARK: - Spies

private final class SpyGrantWriter: CloudConnectionGrantWriterProtocol, @unchecked Sendable {
    struct Grant: Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
        let bundleIds: [String]?
    }

    struct Revoke: Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var recordedConfirmingGrants: [Grant] = []
    private var recordedRevokes: [Revoke] = []
    private var errors: [String: Error] = [:]

    var confirmingGrants: [Grant] { lock.withLock { recordedConfirmingGrants } }
    var revokes: [Revoke] { lock.withLock { recordedRevokes } }
    var errorsByConnectionId: [String: Error] {
        get { lock.withLock { errors } }
        set { lock.withLock { errors = newValue } }
    }

    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {}

    func grantConnectionConfirmingBackend(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        lock.withLock {
            recordedConfirmingGrants.append(Grant(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId,
                bundleIds: bundleIds
            ))
        }
        if let error = errorsByConnectionId[connectionId] {
            throw error
        }
    }

    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws {
        lock.withLock {
            recordedRevokes.append(Revoke(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId
            ))
        }
    }
}

private final class SpyEventWriter: ConnectionEventWriterProtocol, @unchecked Sendable {
    struct Event: Equatable {
        let providerId: String
        let grantedToInboxId: String?
        let conversationId: String
    }

    private let lock = NSLock()
    private var granted: [Event] = []

    var grantedEvents: [Event] { lock.withLock { granted } }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        lock.withLock {
            granted.append(Event(
                providerId: providerId,
                grantedToInboxId: grantedToInboxId,
                conversationId: conversationId
            ))
        }
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {}
}

private struct StubConnectionsRepository: CloudConnectionRepositoryProtocol {
    let stubbedConnections: [CloudConnection]
    let stubbedGrants: [CloudConnectionGrant]

    func connections() async throws -> [CloudConnection] {
        stubbedConnections
    }

    func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        Just(stubbedConnections).eraseToAnyPublisher()
    }

    func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        stubbedGrants.filter { $0.conversationId == conversationId }
    }

    func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        Just(stubbedGrants).eraseToAnyPublisher()
    }
}
