@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing

private let testEnvironment = AppEnvironment.tests

/// Direct-add regression coverage for `ConversationMetadataWriter.addMembers`.
///
/// `conversation_members.inboxId` references `member(inboxId)`. In the invite
/// flow every member's parent row was written by the stream (welcome/profile)
/// before any membership row, so the writer never had to create one.
/// Direct-add is the first path that locally inserts an inboxId the database
/// has never seen — a freshly provisioned agent — which used to fail with
/// SQLite error 19 (FOREIGN KEY constraint) and surface in the UI as
/// "Agent not able to join".
@Suite("Direct-add member persistence", .serialized, .timeLimit(.minutes(3)))
struct DirectAddMemberPersistenceTests {
    @Test("addMembers persists a never-seen inboxId without violating the member FK")
    func testAddMembersPersistsNeverSeenInbox() async throws {
        let fixtures = TestFixtures()
        let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await stateMachine.create(initialMemberInboxIds: [])

        var conversationId: String?
        do {
            conversationId = try await withTimeout(seconds: 30) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let readyResult) = state {
                        return readyResult.conversationId
                    }
                    if case .error(let error) = state {
                        Issue.record("Unexpected error: \(error)")
                        return nil
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for ready: \(error)")
        }
        let convId = try #require(conversationId, "Should reach ready with a conversation id")

        // A second real inbox that exists on the network but that this
        // client's local database has never observed — the same shape as a
        // freshly provisioned agent inbox in the direct-add flow.
        let (clientB, _, _) = try await fixtures.createClient()
        let neverSeenInboxId = clientB.inboxId

        let preExisting = try await fixtures.databaseManager.dbReader.read { db in
            try DBMember.fetchOne(db, key: neverSeenInboxId)
        }
        #expect(preExisting == nil, "Test premise: the inbox must be unknown to the local database")

        try await messagingService.conversationMetadataWriter()
            .addMembers([neverSeenInboxId], to: convId)

        let membershipRow = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationMember.fetchOne(
                db,
                key: ["conversationId": convId, "inboxId": neverSeenInboxId]
            )
        }
        #expect(membershipRow != nil, "Membership row must persist for a never-seen inbox")

        let parentRow = try await fixtures.databaseManager.dbReader.read { db in
            try DBMember.fetchOne(db, key: neverSeenInboxId)
        }
        #expect(parentRow != nil, "Member parent row must be created alongside the membership row")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }
}
