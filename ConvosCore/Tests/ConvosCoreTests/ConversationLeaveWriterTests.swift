@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Self-removal flow coverage: transfer super admin when the leaver is the
/// sole super admin, demote a super-admin leaver (the protocol rejects a
/// super admin's `leaveGroup`), self-remove via `leaveGroup`, then apply the
/// optimistic consent-hide. These tests pin the call sequence, the
/// super-admin invariant, and the human-preferred / agent-fallback successor
/// policy without standing up a real MLS group.
@Suite("ConversationLeaveWriter — transfer-and-leave flow", .serialized)
struct ConversationLeaveWriterTests {
    private let conversationId = "conv-leave-1"
    private let selfInboxId = "inbox-self"
    private let elder = "inbox-elder"
    private let younger = "inbox-younger"

    private let earliest = Date(timeIntervalSince1970: 1_000)
    private let latest = Date(timeIntervalSince1970: 3_000)

    private func human(_ inboxId: String, joinedAt: Date?) -> LeaveSuccessorCandidate {
        LeaveSuccessorCandidate(inboxId: inboxId, isAgent: false, joinedAt: joinedAt)
    }

    private func agent(_ inboxId: String, joinedAt: Date?) -> LeaveSuccessorCandidate {
        LeaveSuccessorCandidate(inboxId: inboxId, isAgent: true, joinedAt: joinedAt)
    }

    @Test("Not sole super admin: demote self + leave + consent-hide, no transfer")
    func noTransferWhenAnotherSuperAdminExists() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId, elder])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest), human(younger, joinedAt: latest)]
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        #expect(fixtures.operations.calls.contains(
            .demoteFromSuperAdmin(inboxId: selfInboxId, conversationId: conversationId)
        ))
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
        #expect(fixtures.consentWriter.deletedConversations.first?.id == conversationId)
    }

    @Test("Not a super admin: leave + consent-hide, no transfer, no demotion")
    func noTransferWhenNotSuperAdmin() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        let hasDemote = fixtures.operations.calls.contains { call in
            if case .demoteFromSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        #expect(!hasDemote)
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin: promotes longest-tenured human, demotes self, then leaves")
    func transfersToLongestTenuredBeforeLeaving() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        // Input order is younger-first; the writer must still pick the
        // earlier-joined (longest-tenured) human, elder.
        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(younger, joinedAt: latest), human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.operations.calls == [
            .currentInboxId,
            .superAdminInboxIds(conversationId: conversationId),
            .promoteToSuperAdmin(inboxId: elder, conversationId: conversationId),
            .demoteFromSuperAdmin(inboxId: selfInboxId, conversationId: conversationId),
            .leaveGroup(conversationId: conversationId)
        ])
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin: a human wins over a longer-tenured agent")
    func humanPreferredOverLongerTenuredAgent() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        // The agent joined earliest, but a human must still be promoted.
        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [agent("inbox-agent", joinedAt: earliest), human(younger, joinedAt: latest)]
        )

        #expect(fixtures.operations.calls.contains(
            .promoteToSuperAdmin(inboxId: younger, conversationId: conversationId)
        ))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin with only agents left: falls back to longest-tenured agent")
    func agentFallbackWhenNoHumansRemain() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [agent("inbox-agent-new", joinedAt: latest), agent("inbox-agent-old", joinedAt: earliest)]
        )

        #expect(fixtures.operations.calls.contains(
            .promoteToSuperAdmin(inboxId: "inbox-agent-old", conversationId: conversationId)
        ))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin with no successor: leaves without transfer or demotion")
    func soleSuperAdminNoSuccessor() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: []
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        let hasDemote = fixtures.operations.calls.contains { call in
            if case .demoteFromSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        #expect(!hasDemote)
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Benign leaveGroup error is swallowed; consent-hide still runs")
    func benignLeaveErrorStillHides() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "GroupError: LeaveCantProcessed cannot leave a group that has only one member"
        ))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Group already gone at leaveGroup: consent-hide still runs")
    func conversationNotFoundOnLeaveStillHides() async throws {
        // Another admin removed us first (or the group was purged); the
        // leave's goal is already achieved and only the local hide remains.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: ConversationLeaveError.conversationNotFound(conversationId))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.consentWriter.deletedConversations.count == 1)
        #expect(fixtures.consentWriter.deletedConversations.first?.id == conversationId)
    }

    @Test("Group already gone at the super-admin lookup: consent-hide still runs")
    func conversationNotFoundOnSuperAdminLookupStillHides() async throws {
        // The not-found can surface from the pre-leave super-admin check,
        // before leaveGroup is ever reached; it must be benign there too.
        let fixtures = Fixtures()
        fixtures.operations.failSuperAdmins(with: ConversationLeaveError.conversationNotFound(conversationId))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        let hasLeave = fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId))
        #expect(!hasLeave)
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Concurrent removal (NotFound::MlsGroup) is benign; consent-hide still runs")
    func concurrentRemovalStillHides() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "GenericError: GroupError NotFound::MlsGroup"
        ))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Concurrent removal (not a group member) is benign; consent-hide still runs")
    func notAGroupMemberStillHides() async throws {
        // We were removed between the roster snapshot and the leave-request;
        // the leave's goal is already achieved.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "[GroupError::LeaveCantProcessed] Group error: only a member of the group can send a leave request or retract a leave request"
        ))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Leave already pending (retry or another installation) is benign; consent-hide still runs")
    func leaveAlreadyPendingStillHides() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "[GroupError::LeaveCantProcessed] Group error: inbox ID already exists in the pending leave list"
        ))

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [human(elder, joinedAt: earliest)]
        )

        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("A super-admin leave rejection is not benign: it propagates and skips the hide")
    func superAdminRejectionPropagates() async throws {
        // If this fires the pre-leave demotion did not land and the user is
        // still a member; hiding the conversation would fake a leave.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "[GroupError::LeaveCantProcessed] Group error: super-admin cannot leave a group; must be demoted first"
        ))

        await #expect(throws: BenignLeaveError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    @Test("A DM leave rejection is not benign: it propagates and skips the hide")
    func dmRejectionPropagates() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "[GroupError::LeaveCantProcessed] Group error: cannot leave a DM conversation"
        ))

        await #expect(throws: BenignLeaveError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    @Test("Consent-hide failure after a committed leave surfaces the typed post-leave error")
    func hideFailureAfterLeaveSurfacesTypedError() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.consentWriter.deleteError = StubError.hideFailed

        do {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
            Issue.record("Expected hideFailedAfterLeave to be thrown")
        } catch ConversationLeaveError.hideFailedAfterLeave(let id, _) {
            #expect(id == conversationId)
        }

        // The MLS self-removal did commit; the caller must treat the
        // conversation as left despite the error.
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
    }

    @Test("Hide failure after a benign-swallowed leave propagates the raw error, not the post-leave case")
    func hideFailureAfterBenignLeavePropagatesRawError() async throws {
        // The single-member rejection means the leave never committed and the
        // user is still a member; wrapping the hide failure as
        // hideFailedAfterLeave would make the caller announce a completed
        // leave that did not happen.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: BenignLeaveError(
            description: "[GroupError::LeaveCantProcessed] Group error: cannot leave a group that has only one member"
        ))
        fixtures.consentWriter.deleteError = StubError.hideFailed

        await #expect(throws: StubError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }
    }

    @Test("A successor who announced departure after the snapshot is skipped, not promoted")
    func promoteSkipsCandidateWithAnnouncedDeparture() async throws {
        // libxmtp accepts a pending leaver in the admin list, so the
        // promotion-rejection fallback alone cannot catch this; the departure
        // markers must be re-checked right before each promotion attempt.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])
        try fixtures.markDeparture(inboxId: elder, conversationId: conversationId)

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [
                human(elder, joinedAt: earliest),
                human(younger, joinedAt: latest),
            ]
        )

        let hasElderPromote = fixtures.operations.calls.contains(
            .promoteToSuperAdmin(inboxId: elder, conversationId: conversationId)
        )
        #expect(!hasElderPromote)
        #expect(fixtures.operations.calls.contains(
            .promoteToSuperAdmin(inboxId: younger, conversationId: conversationId)
        ))
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Every successor announced departure: the leave aborts with no promotion")
    func allSuccessorsDepartedAbortsLeave() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])
        try fixtures.markDeparture(inboxId: elder, conversationId: conversationId)
        try fixtures.markDeparture(inboxId: younger, conversationId: conversationId)

        await #expect(throws: ConversationLeaveError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [
                    human(elder, joinedAt: earliest),
                    human(younger, joinedAt: latest),
                ]
            )
        }

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        let hasLeave = fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId))
        #expect(!hasLeave)
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    @Test("Stale first successor falls back to the next candidate")
    func promoteFallsBackToNextCandidate() async throws {
        // The candidate snapshot is taken before the leave executes; the
        // preferred successor can have left meanwhile. Their rejected
        // promotion must not abort the leave while valid candidates remain.
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])
        fixtures.operations.failPromote(forInboxId: elder, with: StubError.promoteFailed)

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            successorCandidates: [
                human(elder, joinedAt: earliest),
                human(younger, joinedAt: latest),
            ]
        )

        #expect(fixtures.operations.calls.contains(.promoteToSuperAdmin(inboxId: elder, conversationId: conversationId)))
        #expect(fixtures.operations.calls.contains(.promoteToSuperAdmin(inboxId: younger, conversationId: conversationId)))
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Non-benign leaveGroup error propagates and skips the consent-hide")
    func nonBenignLeaveErrorPropagates() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])
        fixtures.operations.failLeave(with: StubError.leaveFailed)

        await #expect(throws: StubError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    @Test("Super-admin transfer failure aborts the leave to protect the invariant")
    func promoteFailureAbortsLeave() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])
        fixtures.operations.failPromote(with: StubError.promoteFailed)

        await #expect(throws: StubError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }

        let hasLeave = fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId))
        #expect(!hasLeave)
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    @Test("Self-demotion failure aborts the leave before leaveGroup")
    func demoteFailureAbortsLeave() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId, elder])
        fixtures.operations.failDemote(with: StubError.demoteFailed)

        await #expect(throws: StubError.self) {
            try await fixtures.writer.leave(
                conversation: .mock(id: conversationId),
                successorCandidates: [human(elder, joinedAt: earliest)]
            )
        }

        let hasLeave = fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId))
        #expect(!hasLeave)
        #expect(fixtures.consentWriter.deletedConversations.isEmpty)
    }

    // MARK: - Fixtures

    private final class Fixtures {
        let operations: MockLeaveGroupOperations
        let consentWriter: MockConversationConsentWriter
        let database: MockDatabaseManager
        let writer: ConversationLeaveWriter

        init() {
            ConvosLog.configure(environment: .tests)
            let ops = MockLeaveGroupOperations()
            ops.setInboxId("inbox-self")
            let consent = MockConversationConsentWriter()
            let database = MockDatabaseManager.makeTestDatabase()
            self.operations = ops
            self.consentWriter = consent
            self.database = database
            self.writer = ConversationLeaveWriter(
                operations: ops,
                consentWriter: consent,
                databaseReader: database.dbReader
            )
        }

        /// Seeds a departure marker: the state a candidate gains when their
        /// leave-request is ingested after the successor snapshot was taken.
        func markDeparture(inboxId: String, conversationId: String) throws {
            try database.dbWriter.write { db in
                try DBMemberDeparture(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    dateNs: 1
                ).save(db)
            }
        }
    }

    private enum StubError: Error {
        case leaveFailed
        case promoteFailed
        case demoteFailed
        case hideFailed
    }

    private struct BenignLeaveError: Error, CustomStringConvertible {
        let description: String
    }
}
