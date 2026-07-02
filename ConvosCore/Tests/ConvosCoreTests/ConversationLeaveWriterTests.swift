@testable import ConvosCore
import Foundation
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
        let writer: ConversationLeaveWriter

        init() {
            ConvosLog.configure(environment: .tests)
            let ops = MockLeaveGroupOperations()
            ops.setInboxId("inbox-self")
            let consent = MockConversationConsentWriter()
            self.operations = ops
            self.consentWriter = consent
            self.writer = ConversationLeaveWriter(
                operations: ops,
                consentWriter: consent
            )
        }
    }

    private enum StubError: Error {
        case leaveFailed
        case promoteFailed
        case demoteFailed
    }

    private struct BenignLeaveError: Error, CustomStringConvertible {
        let description: String
    }
}
