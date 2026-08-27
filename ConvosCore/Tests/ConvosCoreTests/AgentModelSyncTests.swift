import ConvosAppData
@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

/// Covers the agent model's trip through the client: the appData blob it
/// travels in, the column it lands in, and the transcript row a change leaves
/// behind (CON-958).
///
/// The model deliberately does not follow the participation mode everywhere it
/// goes, and the differences are what most of these pin: it is scoped to one
/// agent rather than to the room, it is read-only on the client, and an agent
/// carrying no model is not an agent on a known one.
@Suite("Agent model sync", .serialized)
struct AgentModelSyncTests {
    private static let agentInboxId = "aa".repeat(32)
    private static let otherAgentInboxId = "bb".repeat(32)
    private static let currentInboxId = "cc".repeat(32)
    private static let conversationId = "convo-agent-model"

    // MARK: - Migration

    @Test("migration adds a nullable agentModel column and leaves existing rows unset")
    func migrationAddsNullableColumn() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "conversation_members") { t in
                t.column("conversationId", .text).notNull()
                t.column("inboxId", .text).notNull()
                t.primaryKey(["conversationId", "inboxId"])
            }
            try db.execute(
                sql: "INSERT INTO conversation_members (conversationId, inboxId) VALUES (?, ?)",
                arguments: ["convo-1", Self.agentInboxId]
            )

            try SharedDatabaseMigrator.addConversationMemberAgentModel(db)
        }

        let stored: String? = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT agentModel FROM conversation_members WHERE conversationId = ?",
                arguments: ["convo-1"]
            )
        }
        #expect(stored == nil)
    }

    // MARK: - appData wire format

    @Test("a model survives the appData blob a group metadata commit carries")
    func modelSurvivesAppDataRoundTrip() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        profile.model = "anthropic/claude-sonnet-5"
        var metadata = ConversationCustomMetadata()
        metadata.tag = "tag"
        metadata.profiles = [profile]

        let decoded = try ConversationCustomMetadata.fromCompactString(metadata.toCompactString())

        #expect(decoded.profiles.first?.model == "anthropic/claude-sonnet-5")
        #expect(decoded.tag == "tag")
    }

    /// The whole reason this hangs off the profile rather than the conversation:
    /// a room can hold several agents and they do not share a model.
    @Test("two agents in one conversation carry independent models")
    func twoAgentsCarryIndependentModels() throws {
        var first = ConversationProfile()
        first.inboxID = Data(repeating: 0xAA, count: 32)
        first.model = "anthropic/claude-sonnet-5"
        var second = ConversationProfile()
        second.inboxID = Data(repeating: 0xBB, count: 32)
        second.model = "anthropic/claude-haiku-4-5"
        var metadata = ConversationCustomMetadata()
        metadata.profiles = [first, second]

        let decoded = try ConversationCustomMetadata.fromCompactString(metadata.toCompactString())

        #expect(decoded.profiles.count == 2)
        #expect(decoded.profiles[0].model == "anthropic/claude-sonnet-5")
        #expect(decoded.profiles[1].model == "anthropic/claude-haiku-4-5")
    }

    /// An agent nobody has switched runs whatever its own template shipped, and
    /// the blob cannot name that. Reading absent as "" would let the client
    /// claim it knows something it does not.
    @Test("an unset model reads as no model, not as an empty one")
    func unsetModelReadsAsAbsent() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        var metadata = ConversationCustomMetadata()
        metadata.profiles = [profile]

        let decoded = try ConversationCustomMetadata.fromCompactString(metadata.toCompactString())

        #expect(decoded.profiles.first?.hasModel == false)
    }

    // MARK: - Writing a pick into appData

    /// The pick is written from the picking member's device, which is what puts
    /// their name on the transcript row instead of the agent's.
    @Test("writing a model leaves every other agent's entry alone")
    func writingModelLeavesOtherAgentsAlone() throws {
        var mine = ConversationProfile()
        mine.inboxID = Data(repeating: 0xAA, count: 32)
        mine.model = "anthropic/claude-haiku-4-5"
        var other = ConversationProfile()
        other.inboxID = Data(repeating: 0xBB, count: 32)
        other.model = "openai/gpt-5.5"
        var metadata = ConversationCustomMetadata()
        metadata.tag = "tag"
        metadata.profiles = [mine, other]

        applyAgentModel("anthropic/claude-sonnet-5", to: &metadata, forAgent: Self.agentInboxId)

        #expect(metadata.profiles[0].model == "anthropic/claude-sonnet-5")
        #expect(metadata.profiles[1].model == "openai/gpt-5.5")
    }

    /// Profiles travel as ProfileUpdate messages and appData holds one only for
    /// a member with an avatar, so there is usually nothing to hang a model on.
    @Test("writing a model authors the agent's profile when there is none")
    func writingModelAuthorsProfile() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "tag"

        applyAgentModel(
            "anthropic/claude-sonnet-5",
            to: &metadata,
            forAgent: Self.agentInboxId,
            name: "picker-test"
        )

        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].model == "anthropic/claude-sonnet-5")
        #expect(metadata.profiles[0].name == "picker-test")
    }

    /// Nothing to take back, so nothing is worth a commit.
    @Test("clearing a model the room never carried authors nothing")
    func clearingUnknownModelAuthorsNothing() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "tag"

        applyAgentModel(nil, to: &metadata, forAgent: Self.agentInboxId)

        #expect(metadata.profiles.isEmpty)
    }

    // MARK: - Model name rendering

    /// The transcript has only the id to work from, and a raw
    /// `openai/gpt-5.6-luna` is not something to show a member.
    @Test("a model id renders as a name, without its provider")
    func modelIdRendersAsName() {
        #expect(displayNameForModelId("openai/gpt-5.6-luna") == "GPT 5.6 Luna")
        #expect(displayNameForModelId("anthropic/claude-sonnet-5") == "Claude Sonnet 5")
        #expect(displayNameForModelId("x-ai/grok-4.6") == "Grok 4.6")
        #expect(displayNameForModelId("z-ai/glm-5.2") == "GLM 5.2")
        #expect(displayNameForModelId("moonshotai/kimi-k3") == "Kimi K3")
    }

    /// The `~` prefix marks an auxiliary entry in the agent's catalogue. It is
    /// bookkeeping, and a member reading the transcript should never see it.
    @Test("an auxiliary marker and a bare id both render")
    func markerAndBareIdRender() {
        #expect(displayNameForModelId("~google/gemini-flash-latest") == "Gemini Flash Latest")
        #expect(displayNameForModelId("grok-4.6") == "Grok 4.6")
    }

    // MARK: - Transcript rendering

    @Test("a model change decodes into an agent-model update row")
    func modelChangeProducesAgentModelChange() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        before.profiles = [profile]

        var switched = profile
        switched.model = "anthropic/claude-sonnet-5"
        var after = before
        after.profiles = [switched]

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field == ConversationUpdate.MetadataChange.Field.agentModel.rawValue)
        #expect(change.newValue == "anthropic/claude-sonnet-5")
        #expect(change.oldValue == nil)
        #expect(ConversationUpdate.MetadataChange.Field.agentModel.showsInMessagesList)
    }

    @Test("switching from one model to another carries the model left behind")
    func modelChangeCarriesPreviousModel() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        profile.model = "anthropic/claude-haiku-4-5"
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        before.profiles = [profile]

        var switched = profile
        switched.model = "anthropic/claude-sonnet-5"
        var after = before
        after.profiles = [switched]

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.oldValue == "anthropic/claude-haiku-4-5")
        #expect(change.newValue == "anthropic/claude-sonnet-5")
    }

    /// Same rule the participation mode follows: the commit that first authors
    /// the invite tag is the room's starting state, not a member's choice.
    @Test("the creator seed (tag and model set together) leaves no agent-model row")
    func creatorSeedStaysSilent() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        profile.model = "anthropic/claude-sonnet-5"
        let before = ConversationCustomMetadata()
        var after = ConversationCustomMetadata()
        after.tag = "tag"
        after.profiles = [profile]

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field != ConversationUpdate.MetadataChange.Field.agentModel.rawValue)
    }

    /// Switching an agent back to its own default removes the key rather than
    /// setting it to something, and a scan of only the new side never visits a
    /// removed key — so this change used to leave no transcript row at all.
    @Test("clearing a model still produces an agent-model row")
    func clearingModelProducesAgentModelChange() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        profile.model = "anthropic/claude-sonnet-5"
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        before.profiles = [profile]

        var cleared = profile
        cleared.clearModel()
        var after = before
        after.profiles = [cleared]

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field == ConversationUpdate.MetadataChange.Field.agentModel.rawValue)
        #expect(change.oldValue == "anthropic/claude-sonnet-5")
        #expect(change.newValue == nil)
    }

    /// A commit that changed something else entirely must not be read as a
    /// model change just because the profiles are present in both blobs.
    @Test("an unrelated change leaves no agent-model row")
    func unrelatedChangeStaysSilent() throws {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0xAA, count: 32)
        profile.model = "anthropic/claude-sonnet-5"
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        before.profiles = [profile]
        var after = before
        after.emoji = "🎧"

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field != ConversationUpdate.MetadataChange.Field.agentModel.rawValue)
    }

    // MARK: - Reaching the surface that renders it

    @Test("a stored model reaches the hydrated member the picker reads")
    func storedModelReachesHydratedMember() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversationWithAgent(db: db, model: "anthropic/claude-sonnet-5")
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let conversation = try repo.findOneToOne(with: Self.agentInboxId, excluding: nil)

        let agent = conversation?.membersWithoutCurrent.first { $0.profile.inboxId == Self.agentInboxId }
        #expect(agent?.agentModel == "anthropic/claude-sonnet-5")
    }

    @Test("a member nobody has switched hydrates with no model rather than a guessed one")
    func unswitchedMemberHydratesWithoutAModel() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversationWithAgent(db: db, model: nil)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let conversation = try repo.findOneToOne(with: Self.agentInboxId, excluding: nil)

        let agent = conversation?.membersWithoutCurrent.first { $0.profile.inboxId == Self.agentInboxId }
        #expect(agent != nil)
        #expect(agent?.agentModel == nil)
    }

    /// A 1:1 between the current user and the agent, carrying every row the
    /// detailed conversation query joins as required.
    private static func seedConversationWithAgent(db: Database, model: String?) throws {
        let now = Date()
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(inboxId: currentInboxId, clientId: "client-current", createdAt: now)
            .save(db, onConflict: .ignore)
        try DBMember(inboxId: agentInboxId).save(db, onConflict: .ignore)

        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: now,
            name: nil,
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
            hasHadVerifiedAgent: true
        ).insert(db)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: now,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: true,
            hasSharedInvite: false
        ).insert(db)

        try seedMember(db: db, inboxId: currentInboxId, role: .superAdmin, model: nil)
        try seedMember(db: db, inboxId: agentInboxId, role: .member, model: model)
    }

    private static func seedMember(
        db: Database,
        inboxId: String,
        role: MemberRole,
        model: String?
    ) throws {
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil,
            agentModel: model
        ).insert(db)
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            name: inboxId,
            avatar: nil
        ).insert(db, onConflict: .ignore)
    }
}

private extension String {
    func `repeat`(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
