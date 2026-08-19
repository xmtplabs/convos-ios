@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Origin-scoping for approvals raised in an agent DM: grant-side writes
/// must target the DM's origin group (a DM-scoped grant authorizes nothing
/// backend-side), an unresolvable origin blocks the approval instead of
/// silently falling through to the DM id, and a resolved scope always names
/// its target so the sheet can disclose it.
@Suite("Capability grant scope resolution")
struct CapabilityGrantScopeResolutionTests {
    private let dmId: String = "agent-dm-1"
    private let originId: String = "origin-group-1"
    private let viewer: String = "current-user"
    private let agent: String = "asker-agent"

    private struct Fixture {
        let dbManager: any DatabaseManagerProtocol

        var dbReader: any DatabaseReader { dbManager.dbReader }
        var dbWriter: any DatabaseWriter { dbManager.dbWriter }
    }

    private func makeFixture() -> Fixture {
        Fixture(dbManager: MockDatabaseManager.makeTestDatabase())
    }

    private func seedConversation(
        _ db: Database,
        id: String,
        name: String?,
        isAgentDm: Bool,
        members: [String],
        withLocalState: Bool = true
    ) throws {
        for inboxId in members {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "invite-\(id)",
            creatorId: members.first ?? "creator",
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: name,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false,
            isAgentDm: isAgentDm
        ).insert(db)
        if withLocalState {
            try ConversationLocalState(
                conversationId: id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                hidesInviteCard: false,
                leftHostedInviteSession: false,
                wasRemoved: false,
                hasHadOtherMembers: false,
                hasSharedInvite: false
            ).insert(db)
        }
        for (index, inboxId) in members.enumerated() {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: index == 0 ? .superAdmin : .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
    }

    /// Seeds the standard shape: an agent DM (viewer + agent) plus an origin
    /// group whose membership the caller controls.
    private func seedDmAndOrigin(
        _ fixture: Fixture,
        originName: String? = "Space Camp",
        originMembers: [String]? = nil,
        recordOriginRow: Bool = true
    ) throws {
        try fixture.dbWriter.write { db in
            try seedConversation(db, id: dmId, name: nil, isAgentDm: true, members: [viewer, agent])
            try seedConversation(
                db,
                id: originId,
                name: originName,
                isAgentDm: false,
                members: originMembers ?? [viewer, agent, "other-member"]
            )
            if recordOriginRow {
                try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: originId, in: db)
            }
        }
    }

    private func resolve(
        _ fixture: Fixture,
        conversationId: String,
        isAgentDm: Bool = true,
        liveMarkerOrigin: @escaping @Sendable () async -> String? = { nil }
    ) async -> CapabilityGrantScopeResolution {
        await CapabilityGrantScopeResolution.resolve(
            conversationId: conversationId,
            isAgentDm: isAgentDm,
            askerInboxId: agent,
            viewerInboxId: viewer,
            dbReader: fixture.dbReader,
            liveMarkerOrigin: liveMarkerOrigin
        )
    }

    @Test("a plain group scopes to itself with its own name — today's exact behavior")
    func plainGroupScopesToItself() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: "group-1", name: "Weekend Plans", isAgentDm: false, members: [viewer, agent])
        }
        let resolution = await resolve(fixture, conversationId: "group-1", isAgentDm: false)
        #expect(resolution.scope == .conversation("group-1"))
        #expect(resolution.scope.grantScopeConversationId == "group-1")
        #expect(resolution.scopeDisplayName == "Weekend Plans")
    }

    @Test("an agent DM with an origin row scopes to the origin group and names it")
    func dmWithOriginRowScopesToOrigin() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture)
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .originGroup(originId))
        #expect(resolution.scope.grantScopeConversationId == originId)
        #expect(resolution.scopeDisplayName == "Space Camp")
    }

    @Test("the live appData marker is not consulted when the mirror row exists")
    func markerNotConsultedWhenRowPresent() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture)
        let consulted = MarkerProbe()
        _ = await resolve(fixture, conversationId: dmId, liveMarkerOrigin: {
            consulted.trip()
            return nil
        })
        #expect(consulted.tripped == false)
    }

    @Test("a missing mirror row falls back to the live appData marker")
    func dmWithoutRowFallsBackToMarker() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture, recordOriginRow: false)
        let originId = self.originId
        let resolution = await resolve(fixture, conversationId: dmId, liveMarkerOrigin: { originId })
        #expect(resolution.scope == .originGroup(originId))
        #expect(resolution.scopeDisplayName == "Space Camp")
    }

    @Test("no row and no marker blocks the approval with the still-syncing copy")
    func dmWithoutRowOrMarkerBlocks() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture, recordOriginRow: false)
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.originUnknown))
        #expect(resolution.scope.grantScopeConversationId == nil)
        #expect(resolution.scopeDisplayName == nil)
        #expect(CapabilityGrantScopeBlockReason.originUnknown.userFacingMessage.contains("still syncing"))
    }

    @Test("an origin the device has not synced blocks with the still-syncing copy")
    func dmOriginNotSyncedBlocks() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: dmId, name: nil, isAgentDm: true, members: [viewer, agent])
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: "never-synced", in: db)
        }
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.originNotSynced))
        #expect(CapabilityGrantScopeBlockReason.originNotSynced.userFacingMessage.contains("still syncing"))
    }

    @Test("a departed origin blocks with the no-longer-in copy")
    func dmDepartedOriginBlocks() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture, originMembers: [agent, "other-member"])
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.userNotInOrigin))
        #expect(CapabilityGrantScopeBlockReason.userNotInOrigin.userFacingMessage == "This request belongs to a conversation you're no longer in.")
    }

    @Test("a recorded departure blocks even while the member row is still present")
    func dmRecordedDepartureBlocks() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture)
        try await fixture.dbWriter.write { [self] db in
            try DBMemberDeparture(conversationId: originId, inboxId: viewer, dateNs: 1).insert(db)
        }
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.userNotInOrigin))
    }

    @Test("an origin the asking agent is no longer in blocks — rebind staleness")
    func dmAgentNotInOriginBlocks() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture, originMembers: [viewer, "other-member"])
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.agentNotInOrigin))
        #expect(CapabilityGrantScopeBlockReason.agentNotInOrigin.userFacingMessage.contains("still syncing"))
    }

    @Test("an unnamed origin approves with its member-derived identity — the same name the rest of the app shows")
    func unnamedOriginApprovesWithDerivedName() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture, originName: nil)
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .originGroup(originId))
        let name = try #require(resolution.scopeDisplayName)
        #expect(!name.isEmpty)
    }

    @Test("an origin whose identity cannot be derived blocks with honest copy")
    func unidentifiableOriginBlocks() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: dmId, name: nil, isAgentDm: true, members: [viewer, agent])
            // No local-state row: the identity hydration's required join
            // fails, modelling a partially synced origin.
            try seedConversation(db, id: originId, name: nil, isAgentDm: false, members: [viewer, agent], withLocalState: false)
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: originId, in: db)
        }
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.originUnidentifiable))
        #expect(CapabilityGrantScopeBlockReason.originUnidentifiable.userFacingMessage == "Can't identify the conversation this request belongs to.")
    }

    @Test("an origin marker naming the DM itself blocks — member-writable input must not steer the scope")
    func originNamingDmItselfBlocks() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: dmId, name: nil, isAgentDm: true, members: [viewer, agent])
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: dmId, in: db)
        }
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.originNotAGroup))
        #expect(resolution.scope.grantScopeConversationId == nil)
    }

    @Test("an origin that is itself an agent DM blocks")
    func originBeingAnotherAgentDmBlocks() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: dmId, name: nil, isAgentDm: true, members: [viewer, agent])
            // A second agent DM the viewer and agent share: every membership
            // check passes, so only the not-a-group guard can stop it.
            try seedConversation(db, id: "other-agent-dm", name: "Sneaky", isAgentDm: true, members: [viewer, agent])
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: "other-agent-dm", in: db)
        }
        let resolution = await resolve(fixture, conversationId: dmId)
        #expect(resolution.scope == .unresolvableOrigin(.originNotAGroup))
    }

    @Test("a nameless plain group keeps a nil name for the view model's own-conversation fallback")
    func namelessPlainGroupKeepsNilName() async throws {
        let fixture = makeFixture()
        try await fixture.dbWriter.write { [self] db in
            try seedConversation(db, id: "group-unnamed", name: nil, isAgentDm: false, members: [viewer, agent])
        }
        let resolution = await resolve(fixture, conversationId: "group-unnamed", isAgentDm: false)
        #expect(resolution.scope == .conversation("group-unnamed"))
        #expect(resolution.scopeDisplayName == nil)
    }

    @Test("the repository seam resolves the same DM fixture the view model hands it")
    func repositorySeamResolvesDmFixture() async throws {
        let fixture = makeFixture()
        try seedDmAndOrigin(fixture)
        let repository = CapabilityRequestRepository(
            dbReader: fixture.dbReader,
            conversationId: dmId,
            viewerInboxId: viewer
        )
        let resolution = await repository.resolveGrantScope(
            isAgentDm: true,
            askerInboxId: agent,
            liveMarkerOrigin: { nil }
        )
        #expect(resolution.scope == .originGroup(originId))
        #expect(resolution.scopeDisplayName == "Space Camp")
    }

    private final class MarkerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool = false
        var tripped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func trip() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }
}

/// The Agent tab's discoverability surface is the unread dot: a connect
/// request arriving in the member's 1:1 must light it, while result rows and
/// the member's own messages must not.
@Suite("Capability request unread marking")
struct CapabilityRequestUnreadTests {
    @Test("a capability request marks the conversation unread")
    func capabilityRequestMarksUnread() {
        #expect(MessageContentType.capabilityRequest.marksConversationAsUnread)
        #expect(marksConversationUnread(
            contentType: .capabilityRequest,
            senderInboxId: "agent",
            currentInboxId: "me",
            conversationId: "dm-1",
            activeConversationIds: []
        ))
    }

    @Test("a capability result does not mark unread")
    func capabilityResultDoesNotMarkUnread() {
        #expect(MessageContentType.capabilityRequestResult.marksConversationAsUnread == false)
    }

    @Test("the viewer's own messages and the active conversation stay exempt")
    func unreadExemptionsHold() {
        #expect(marksConversationUnread(
            contentType: .capabilityRequest,
            senderInboxId: "me",
            currentInboxId: "me",
            conversationId: "dm-1",
            activeConversationIds: []
        ) == false)
        #expect(marksConversationUnread(
            contentType: .capabilityRequest,
            senderInboxId: "agent",
            currentInboxId: "me",
            conversationId: "dm-1",
            activeConversationIds: ["dm-1"]
        ) == false)
    }

    @Test("the open agent DM is exempt alongside its parent group")
    func activeDmExemptWithParentGroup() {
        // The conversation screen registers both surfaces: the group (its
        // tab bar) and the folded DM (the Agent tab). A request arriving in
        // the DM the user is reading must not mark it unread; a different
        // DM's request still does.
        let active: Set<String> = ["group-1", "dm-1"]
        #expect(marksConversationUnread(
            contentType: .capabilityRequest,
            senderInboxId: "agent",
            currentInboxId: "me",
            conversationId: "dm-1",
            activeConversationIds: active
        ) == false)
        #expect(marksConversationUnread(
            contentType: .capabilityRequest,
            senderInboxId: "agent",
            currentInboxId: "me",
            conversationId: "dm-2",
            activeConversationIds: active
        ))
    }
}
