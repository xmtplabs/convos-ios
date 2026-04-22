@testable import ConvosCore
import Foundation
import Testing

/// Sender-side coverage for the single-inbox explode flow (ADR 004 C9
/// amendment): broadcast `ExplodeSettings`, update local `expiresAt`,
/// remove every *other* member from the MLS group, then `leaveGroup`.
/// `denyConsent` is the fallback when the leave call itself throws.
/// These tests pin the call sequence and the self-filter invariant;
/// integration coverage of the receiver side lives in
/// `IncomingMessageWriterExplodeTests`.
@Suite("ConversationExplosionWriter — remove-and-leave flow", .serialized)
struct ExplodeRemoveAndLeaveTests {
    private let conversationId = "conv-explode-1"
    private let selfInboxId = "inbox-self"
    private let otherA = "inbox-A"
    private let otherB = "inbox-B"

    @Test("Happy path: sendExplode → updateExpiresAt → removeMembers → leaveGroup, no denyConsent")
    func happyPathCallOrder() async throws {
        let fixtures = Fixtures()

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA, otherB]
        )

        #expect(fixtures.operations.calls.count == 3)
        guard fixtures.operations.calls.count == 3 else { return }

        #expect(fixtures.operations.calls[0] == .currentInboxId)

        if case let .sendExplode(cid, _) = fixtures.operations.calls[1] {
            #expect(cid == conversationId)
        } else {
            Issue.record("Expected sendExplode at index 1, got \(fixtures.operations.calls[1])")
        }

        #expect(fixtures.operations.calls[2] == .leaveGroup(conversationId: conversationId))

        #expect(fixtures.metadataWriter.updatedExpiresAt.count == 1)
        #expect(fixtures.metadataWriter.updatedExpiresAt.first?.conversationId == conversationId)

        #expect(fixtures.metadataWriter.removedMembers.count == 1)
        let removed = fixtures.metadataWriter.removedMembers.first
        #expect(removed?.conversationId == conversationId)
        #expect(removed?.memberIds == [otherA, otherB])
    }

    @Test("Self inboxId is filtered out of removeMembers — MLS rejects self-removal")
    func selfIsFilteredFromRemoveMembers() async throws {
        let fixtures = Fixtures()

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA, otherB]
        )

        let removed = fixtures.metadataWriter.removedMembers.first?.memberIds ?? []
        #expect(!removed.contains(selfInboxId), "Creator must not be in the removeMembers list")
        #expect(Set(removed) == Set([otherA, otherB]))
    }

    @Test("leaveGroup failure falls back to denyConsent; writer still succeeds")
    func leaveFailureFallsBackToDenyConsent() async throws {
        let fixtures = Fixtures()
        fixtures.operations.failLeaveGroup(with: StubError.leaveFailed)

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA]
        )

        // currentInboxId → sendExplode → leaveGroup (throws) → denyConsent
        #expect(fixtures.operations.calls.count == 4)
        #expect(fixtures.operations.calls.last == .denyConsent(conversationId: conversationId))
    }

    @Test("Both leaveGroup and denyConsent failing is swallowed, not rethrown")
    func bothLeavePathsFailingIsSwallowed() async throws {
        let fixtures = Fixtures()
        fixtures.operations.failLeaveGroup(with: StubError.leaveFailed)
        fixtures.operations.failDenyConsent(with: StubError.consentFailed)

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA]
        )

        #expect(fixtures.operations.calls.last == .denyConsent(conversationId: conversationId))
    }

    @Test("sendExplode failure is logged but does not abort MLS teardown")
    func sendExplodeFailureDoesNotAbortFlow() async throws {
        // MLS teardown (removeMembers + leaveGroup) is the source of truth
        // for "group ends"; the ExplodeSettings codec message is a best-effort
        // hint so receivers can hide the conversation ahead of the MLS commit
        // arriving. If sendExplode flakes, the remaining legs must still run —
        // partial-destruction (message went out but group still has all
        // members) is strictly worse than a full best-effort sweep.
        let fixtures = Fixtures()
        fixtures.operations.failSendExplode(with: StubError.sendFailed)

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA]
        )

        // currentInboxId → sendExplode (fails) → leaveGroup still fires.
        #expect(fixtures.operations.calls.count == 3)
        #expect(fixtures.operations.calls.last == .leaveGroup(conversationId: conversationId))
        // Local expiresAt + removeMembers both land despite the send failure.
        #expect(fixtures.metadataWriter.updatedExpiresAt.count == 1)
        #expect(fixtures.metadataWriter.removedMembers.count == 1)
    }

    @Test("metadataWriter.removeMembers failure does not prevent leaveGroup")
    func removeMembersFailureStillLeaves() async throws {
        let fixtures = Fixtures()
        fixtures.metadataWriter.removeMembersError = StubError.removeFailed

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA]
        )

        #expect(fixtures.operations.calls.last == .leaveGroup(conversationId: conversationId))
    }

    @Test("currentInboxId throw aborts before any MLS call — session not ready")
    func currentInboxIdThrowAbortsEarly() async throws {
        // If the session never reports ready (keychain load failure, XMTP
        // bootstrap stuck), the writer should propagate and land nothing.
        // Pre-refactor this path was never asserted — adding it pins the
        // contract that explode requires a ready session at entry.
        let fixtures = Fixtures()
        final class ThrowingOperations: ExplodeGroupOperationsProtocol, @unchecked Sendable {
            func currentInboxId() async throws -> String {
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "session not ready"])
            }
            func sendExplode(conversationId: String, expiresAt: Date) async throws {}
            func leaveGroup(conversationId: String) async throws {}
            func denyConsent(conversationId: String) async throws {}
        }
        let throwing = ThrowingOperations()
        let writer = ConversationExplosionWriter(
            operations: throwing,
            metadataWriter: fixtures.metadataWriter
        )

        do {
            try await writer.explodeConversation(
                conversationId: conversationId,
                memberInboxIds: [selfInboxId, otherA]
            )
            Issue.record("Expected currentInboxId failure to propagate")
        } catch {
            // Expected
        }

        // Writer aborted before any MLS call or metadata write.
        #expect(fixtures.metadataWriter.updatedExpiresAt.isEmpty)
        #expect(fixtures.metadataWriter.removedMembers.isEmpty)
    }

    @Test("All three MLS calls fail — writer completes without throwing; denyConsent runs as leave fallback")
    func allMLSOperationsFailingDoesNotThrow() async throws {
        // The category-collapse fix: no single leg's failure aborts the
        // other legs. Even if sendExplode, leaveGroup, and denyConsent
        // all fail, the writer still completes and metadataWriter still
        // gets its calls — a best-effort sweep is strictly better than
        // partial destruction.
        let fixtures = Fixtures()
        fixtures.operations.failSendExplode(with: StubError.sendFailed)
        fixtures.operations.failLeaveGroup(with: StubError.leaveFailed)
        fixtures.operations.failDenyConsent(with: StubError.consentFailed)

        try await fixtures.writer.explodeConversation(
            conversationId: conversationId,
            memberInboxIds: [selfInboxId, otherA]
        )

        // sendExplode, leaveGroup, denyConsent all recorded even though
        // each threw; metadata writes still landed.
        let calls = fixtures.operations.calls
        #expect(calls.contains { if case .sendExplode = $0 { return true } else { return false } })
        #expect(calls.contains(.leaveGroup(conversationId: conversationId)))
        #expect(calls.contains(.denyConsent(conversationId: conversationId)))
        #expect(fixtures.metadataWriter.updatedExpiresAt.count == 1)
        #expect(fixtures.metadataWriter.removedMembers.count == 1)
    }

    @Test("scheduleExplosion sends the message and records expiresAt; never touches leaveGroup")
    func scheduleExplosionDoesNotLeaveGroup() async throws {
        let fixtures = Fixtures()
        let expiresAt = Date().addingTimeInterval(3600)

        try await fixtures.writer.scheduleExplosion(
            conversationId: conversationId,
            expiresAt: expiresAt
        )

        let hasSend = fixtures.operations.calls.contains { call in
            if case .sendExplode(let cid, let date) = call {
                return cid == conversationId && date == expiresAt
            }
            return false
        }
        #expect(hasSend)

        let hasLeave = fixtures.operations.calls.contains { call in
            if case .leaveGroup = call { return true }
            return false
        }
        #expect(!hasLeave)

        #expect(fixtures.metadataWriter.updatedExpiresAt.first?.expiresAt == expiresAt)
    }

    // MARK: - Fixtures

    private final class Fixtures {
        let operations: MockExplodeGroupOperations
        let metadataWriter: RecordingMetadataWriter
        let writer: ConversationExplosionWriter

        init() {
            ConvosLog.configure(environment: .tests)
            let ops = MockExplodeGroupOperations()
            ops.setInboxId("inbox-self")
            let md = RecordingMetadataWriter()
            self.operations = ops
            self.metadataWriter = md
            self.writer = ConversationExplosionWriter(
                operations: ops,
                metadataWriter: md
            )
        }
    }

    private enum StubError: Error {
        case sendFailed
        case leaveFailed
        case consentFailed
        case removeFailed
    }
}

/// `MockConversationMetadataWriter` doesn't let us inject failures on the
/// two methods the explosion writer calls, so the tests use this tiny
/// recording subclass-equivalent that adds error-injection seams on the
/// single paths we care about.
private final class RecordingMetadataWriter: ConversationMetadataWriterProtocol, @unchecked Sendable {
    var updatedExpiresAt: [(expiresAt: Date, conversationId: String)] = []
    var removedMembers: [(memberIds: [String], conversationId: String)] = []
    var removeMembersError: (any Error)?

    func updateName(_ name: String, for conversationId: String) async throws {}
    func updateDescription(_ description: String, for conversationId: String) async throws {}
    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {}
    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {}

    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {
        removedMembers.append((memberIds: memberInboxIds, conversationId: conversationId))
        if let removeMembersError { throw removeMembersError }
    }

    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func updateImage(_ image: ImageType, for conversation: Conversation) async throws {}

    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {
        updatedExpiresAt.append((expiresAt: expiresAt, conversationId: conversationId))
    }

    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws {}
    func lockConversation(for conversationId: String) async throws {}
    func unlockConversation(for conversationId: String) async throws {}
    func refreshInvite(for conversationId: String) async throws -> Invite? { nil }
}
