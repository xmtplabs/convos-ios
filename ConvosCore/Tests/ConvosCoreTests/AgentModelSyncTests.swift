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
}

private extension String {
    func `repeat`(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
