@testable import ConvosCore
import Foundation
import Testing

/// Self-removal flow coverage: transfer super admin when the leaver is the
/// sole super admin, self-remove via `leaveGroup`, then apply the optimistic
/// consent-hide. These tests pin the call sequence and the super-admin
/// invariant without standing up a real MLS group.
@Suite("ConversationLeaveWriter — transfer-and-leave flow", .serialized)
struct ConversationLeaveWriterTests {
    private let conversationId = "conv-leave-1"
    private let selfInboxId = "inbox-self"
    private let elder = "inbox-elder"
    private let younger = "inbox-younger"

    @Test("Not sole super admin: leave + consent-hide, no super-admin transfer")
    func noTransferWhenAnotherSuperAdminExists() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId, elder])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            tenureOrderedSuccessorInboxIds: [elder, younger]
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        #expect(fixtures.operations.calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
        #expect(fixtures.consentWriter.deletedConversations.first?.id == conversationId)
    }

    @Test("Not a super admin: leave + consent-hide, no transfer")
    func noTransferWhenNotSuperAdmin() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([elder])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            tenureOrderedSuccessorInboxIds: [elder, younger]
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin: promotes longest-tenured successor before leaving")
    func transfersToLongestTenuredBeforeLeaving() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            tenureOrderedSuccessorInboxIds: [elder, younger]
        )

        // Order matters: super-admin lookup, promote the first (longest-tenured)
        // successor, then leave. The consent-hide follows.
        #expect(fixtures.operations.calls == [
            .currentInboxId,
            .superAdminInboxIds(conversationId: conversationId),
            .promoteToSuperAdmin(inboxId: elder, conversationId: conversationId),
            .leaveGroup(conversationId: conversationId)
        ])
        #expect(fixtures.consentWriter.deletedConversations.count == 1)
    }

    @Test("Sole super admin with no successor: leaves without transfer")
    func soleSuperAdminNoSuccessor() async throws {
        let fixtures = Fixtures()
        fixtures.operations.setSuperAdmins([selfInboxId])

        try await fixtures.writer.leave(
            conversation: .mock(id: conversationId),
            tenureOrderedSuccessorInboxIds: []
        )

        let hasPromote = fixtures.operations.calls.contains { call in
            if case .promoteToSuperAdmin = call { return true }
            return false
        }
        #expect(!hasPromote)
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
            tenureOrderedSuccessorInboxIds: [elder]
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
                tenureOrderedSuccessorInboxIds: [elder]
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
                tenureOrderedSuccessorInboxIds: [elder]
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
    }

    private struct BenignLeaveError: Error, CustomStringConvertible {
        let description: String
    }
}
