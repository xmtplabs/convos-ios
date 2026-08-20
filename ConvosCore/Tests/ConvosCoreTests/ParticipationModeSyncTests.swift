import ConvosAppData
@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

/// Covers the participation mode's trip through the client: the appData blob it
/// travels in, the column it lands in, and the transcript row a change leaves
/// behind (CON-826).
@Suite("Participation mode sync", .serialized)
struct ParticipationModeSyncTests {
    // MARK: - Migration

    /// `createMigrator()` is private and DEBUG turns on
    /// `eraseDatabaseOnSchemaChange`, so this drives the extracted static helper
    /// against a pre-existing `conversation` row - the upgrade an installed
    /// client actually performs (mirrors `ProfileTablesMigrationTests`).
    @Test("migration adds a nullable participationMode column and leaves existing rows unset")
    func migrationAddsNullableColumn() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: ["convo-1"])

            try SharedDatabaseMigrator.addConversationParticipationMode(db)
        }

        try dbQueue.read { db in
            #expect(try db.columns(in: "conversation").map(\.name).contains("participationMode"))
            let stored = try String.fetchOne(
                db,
                sql: "SELECT participationMode FROM conversation WHERE id = ?",
                arguments: ["convo-1"]
            )
            #expect(stored == nil)
        }
    }

    @Test("the cut listen mode is cleared, so a stale row cannot fail the fetch")
    func migrationClearsCutListenMode() throws {
        // `listen` shipped briefly before the level was cut. The enum has no
        // case for it now and GRDB throws rather than shrugging, so one stale
        // row would fail the whole DBConversation fetch and take the
        // conversation with it.
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: ["convo-listen"])
            try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: ["convo-paused"])
            try SharedDatabaseMigrator.addConversationParticipationMode(db)
            try db.execute(
                sql: "UPDATE conversation SET participationMode = ? WHERE id = ?",
                arguments: ["listen", "convo-listen"]
            )
            try db.execute(
                sql: "UPDATE conversation SET participationMode = ? WHERE id = ?",
                arguments: ["paused", "convo-paused"]
            )

            try SharedDatabaseMigrator.clearCutListenParticipationMode(db)
        }

        try dbQueue.read { db in
            let cleared = try String.fetchOne(
                db,
                sql: "SELECT participationMode FROM conversation WHERE id = ?",
                arguments: ["convo-listen"]
            )
            #expect(cleared == nil)

            // A level this build still has is left exactly where it was.
            let kept = try String.fetchOne(
                db,
                sql: "SELECT participationMode FROM conversation WHERE id = ?",
                arguments: ["convo-paused"]
            )
            #expect(kept == "paused")
        }
    }

    @Test("a stored mode round-trips through the column")
    func storedModeRoundTrips() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try SharedDatabaseMigrator.addConversationParticipationMode(db)
            try db.execute(
                sql: "INSERT INTO conversation (id, participationMode) VALUES (?, ?)",
                arguments: ["convo-1", ConversationParticipationMode.mentionsOnly.rawValue]
            )
        }

        let stored: String? = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT participationMode FROM conversation WHERE id = ?", arguments: ["convo-1"])
        }
        #expect(stored.flatMap(ConversationParticipationMode.init(rawValue:)) == .mentionsOnly)
    }

    // MARK: - appData wire format

    @Test("every mode survives the appData blob a group metadata commit carries")
    func modesSurviveAppDataRoundTrip() throws {
        for mode in ConversationParticipationMode.allCases {
            var metadata = ConversationCustomMetadata()
            metadata.tag = "tag"
            metadata.participationMode = mode.proto

            let decoded = try ConversationCustomMetadata.fromCompactString(metadata.toCompactString())

            #expect(decoded.conversationParticipationMode == mode)
            #expect(decoded.tag == "tag")
        }
    }

    /// A conversation nobody has set a mode on, and one written by a build that
    /// knows a mode this one does not, are the same thing to a reader: no
    /// authored mode, so the default applies rather than an invented one.
    @Test("an unset or unrecognized mode reads as no mode")
    func unsetModeReadsAsNil() throws {
        var unset = ConversationCustomMetadata()
        unset.tag = "tag"
        #expect(unset.conversationParticipationMode == nil)

        var future = ConversationCustomMetadata()
        future.participationMode = .UNRECOGNIZED(99)
        #expect(future.conversationParticipationMode == nil)
    }

    /// Setting the mode must not disturb what else the blob is carrying: the
    /// write path is a read-modify-write of one shared appData value.
    @Test("setting the mode preserves the rest of the metadata")
    func settingModePreservesOtherFields() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "invite-tag"
        metadata.emoji = "🎧"
        metadata.expiresAtUnix = 1_700_000_000
        metadata.participationMode = ConversationParticipationMode.paused.proto

        let decoded = try ConversationCustomMetadata.fromCompactString(metadata.toCompactString())

        #expect(decoded.tag == "invite-tag")
        #expect(decoded.emoji == "🎧")
        #expect(decoded.expiresAtUnix == 1_700_000_000)
        #expect(decoded.conversationParticipationMode == .paused)
    }

    // MARK: - Transcript rendering

    @Test("a mode change decodes into a participation-mode update row")
    func modeChangeProducesParticipationChange() throws {
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        var after = before
        after.participationMode = ConversationParticipationMode.mentionsOnly.proto

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field == ConversationUpdate.MetadataChange.Field.participationMode.rawValue)
        #expect(change.newValue == ConversationParticipationMode.mentionsOnly.rawValue)
        #expect(change.oldValue == nil)
        #expect(ConversationUpdate.MetadataChange.Field.participationMode.showsInMessagesList)
    }

    @Test("appData changes that are not the mode stay out of the transcript")
    func otherAppDataChangesStaySilent() throws {
        var before = ConversationCustomMetadata()
        before.tag = "tag-1"
        before.participationMode = ConversationParticipationMode.paused.proto
        var after = before
        after.tag = "tag-2"

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field == ConversationUpdate.MetadataChange.Field.metadata.rawValue)
        #expect(!ConversationUpdate.MetadataChange.Field.metadata.showsInMessagesList)
    }

    /// Expirations are rendered from the `ExplodeSettings` content type, so the
    /// appData change that carries one must stay silent here - otherwise the
    /// member is told twice.
    @Test("an expiration change still renders nothing from appData")
    func expiryChangeStaysSilent() throws {
        var before = ConversationCustomMetadata()
        before.tag = "tag"
        var after = before
        after.expiresAtUnix = 1_700_000_000

        let change = XMTPiOS.DecodedMessage.appDataMetadataChange(
            oldValue: try before.toCompactString(),
            newValue: try after.toCompactString()
        )

        #expect(change.field == ConversationUpdate.MetadataChange.Field.unknown.rawValue)
        #expect(!ConversationUpdate.MetadataChange.Field.unknown.showsInMessagesList)
    }

    // MARK: - In-memory copies

    /// The optimistic copy helpers overlay one field onto a DB-emitted
    /// conversation; dropping the mode there would revert the control to Speak
    /// freely until the next database read.
    @Test("copy helpers carry the mode through")
    func copyHelpersPreserveMode() throws {
        var conversation: ConvosCore.Conversation = .mock()
        conversation.participationMode = .paused

        #expect(conversation.withMembers([]).participationMode == .paused)
        #expect(conversation.withLeftHostedInviteSession(true).participationMode == .paused)
    }

    @Test("the update reads as who set which mode")
    func updateSummaryNamesTheModeAndSetter() throws {
        let update = ConversationUpdate(
            creator: .mock(isCurrentUser: false, name: "Shane"),
            addedMembers: [],
            removedMembers: [],
            metadataChanges: [
                .init(
                    field: .participationMode,
                    oldValue: nil,
                    newValue: ConversationParticipationMode.mentionsOnly.rawValue
                )
            ]
        )

        #expect(update.summary == "Shane set the participation mode to \"Listen mode\"")
    }

    @Test("a paused update warns that messages will not be seen later")
    func pausedUpdateExplainsDroppedMessages() throws {
        let update = ConversationUpdate(
            creator: .mock(isCurrentUser: false, name: "Shane"),
            addedMembers: [],
            removedMembers: [],
            metadataChanges: [
                .init(
                    field: .participationMode,
                    oldValue: ConversationParticipationMode.speakFreely.rawValue,
                    newValue: ConversationParticipationMode.paused.rawValue
                )
            ]
        )

        #expect(update.summary == "Shane paused the agents. They won't see messages sent while paused, even later")
    }
}
