import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

@Suite("ConnectionEventRouter")
struct ConnectionEventRouterTests {
    private static let agent: String = "agent-inbox"
    private static let origin: String = "origin-group"
    private static let dm: String = "agent-dm"

    private actor RecordingSender: ConnectionEventSending {
        struct Sent: Equatable {
            let event: ConnectionEvent
            let conversationId: String
        }

        private(set) var sent: [Sent] = []
        var failFor: Set<String> = []

        func setFailing(_ conversationIds: Set<String>) {
            failFor = conversationIds
        }

        func send(_ event: ConnectionEvent, in conversationId: String) async throws {
            if failFor.contains(conversationId) {
                throw ConnectionEventWriterError.conversationNotFound(conversationId: conversationId)
            }
            sent.append(Sent(event: event, conversationId: conversationId))
        }

        func allSent() -> [Sent] { sent }
    }

    private func makeRouter(
        sender: RecordingSender,
        dmByAgentAndOrigin: [String: String]
    ) -> ConnectionEventRouter {
        ConnectionEventRouter(sender: sender) { agentInboxId, originConversationId in
            dmByAgentAndOrigin["\(agentInboxId)|\(originConversationId)"]
        }
    }

    @Test("granted with a known DM sends the full event to the DM and a notice copy to the group")
    func grantedRoutesToDmWithGroupNotice() async throws {
        let sender = RecordingSender()
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.origin)": Self.dm])

        try await router.sendGranted(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 2)
        #expect(sent[0].conversationId == Self.dm)
        #expect(sent[0].event.grantedToInboxId == Self.agent)
        #expect(sent[0].event.notice == nil)
        #expect(sent[1].conversationId == Self.origin)
        #expect(sent[1].event.notice == true)
        #expect(sent[1].event.grantedToInboxId == nil, "The group copy is grantee-less discoverability text")
        #expect(sent[1].event.action == .granted)
    }

    @Test("revoked with a known DM sends only the full event to the DM")
    func revokedRoutesToDmOnly() async throws {
        let sender = RecordingSender()
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.origin)": Self.dm])

        try await router.sendRevoked(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.dm)
        #expect(sent[0].event.action == .revoked)
        #expect(sent[0].event.notice == nil)
    }

    @Test("no grantee falls back to the origin conversation")
    func noGranteeSendsToOrigin() async throws {
        let sender = RecordingSender()
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.origin)": Self.dm])

        try await router.sendRevoked(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: nil,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.origin)
        #expect(sent[0].event.notice == nil)
    }

    @Test("unresolvable DM falls back to the origin conversation without a notice")
    func unresolvableDmSendsToOrigin() async throws {
        let sender = RecordingSender()
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: [:])

        try await router.sendGranted(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.origin)
        #expect(sent[0].event.grantedToInboxId == Self.agent)
        #expect(sent[0].event.notice == nil)
    }

    @Test("a DM resolving to the sending conversation itself sends one event, no copy")
    func dmEqualToOriginSendsOnce() async throws {
        let sender = RecordingSender()
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.dm)": Self.dm])

        try await router.sendGranted(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.dm
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.dm)
        #expect(sent[0].event.notice == nil)
    }

    @Test("a failed DM send falls back to the full event in the origin conversation")
    func failedDmSendFallsBack() async throws {
        let sender = RecordingSender()
        await sender.setFailing([Self.dm])
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.origin)": Self.dm])

        try await router.sendGranted(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.origin)
        #expect(sent[0].event.grantedToInboxId == Self.agent)
        #expect(sent[0].event.notice == nil, "The fallback is the authoritative event, not a notice copy")
    }

    @Test("a failed notice copy does not fail the grant flow")
    func failedNoticeCopyIsSwallowed() async throws {
        let sender = RecordingSender()
        await sender.setFailing([Self.origin])
        let router = makeRouter(sender: sender, dmByAgentAndOrigin: ["\(Self.agent)|\(Self.origin)": Self.dm])

        try await router.sendGranted(
            providerId: "composio.googlecalendar",
            capability: nil,
            grantedToInboxId: Self.agent,
            in: Self.origin
        )

        let sent = await sender.allSent()
        #expect(sent.count == 1)
        #expect(sent[0].conversationId == Self.dm)
    }
}
