@testable import ConvosCore
import ConvosInvites
import Foundation
import Testing

@Suite("InviteJoinRequestsManager Tests")
struct InviteJoinRequestsManagerTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let day: TimeInterval = 24 * 60 * 60

    // MARK: - Post-join snapshot routing

    @Test("Accepted join re-publishes the joined conversation's snapshot")
    func acceptedTriggersSnapshot() {
        let result = JoinResult(
            conversationId: "group-1",
            joinerInboxId: "joiner-1",
            conversationName: "Group"
        )
        let outcome = JoinRequestDMOutcome.accepted(result, dmConversationId: "dm-1")
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == "group-1")
    }

    @Test("Verified already-member result re-publishes the snapshot for its conversation")
    func verifiedAlreadyMemberTriggersSnapshot() {
        let outcome = JoinRequestDMOutcome.alreadyMember(
            dmConversationId: "dm-1",
            joinerInboxId: "joiner-1",
            verified: AlreadyMemberContext(conversationId: "group-1", profile: nil, metadata: nil)
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == "group-1")
    }

    @Test("Ledger-only already-member result does not re-publish a snapshot")
    func ledgerAlreadyMemberSkipsSnapshot() {
        let outcome = JoinRequestDMOutcome.alreadyMember(
            dmConversationId: "dm-1",
            joinerInboxId: "joiner-1",
            verified: nil
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == nil)
    }

    @Test("Non-joining outcomes never re-publish a snapshot")
    func nonJoiningOutcomesSkipSnapshot() {
        let benign = JoinRequestDMOutcome.benignFailure(
            dmConversationId: "dm-1",
            senderInboxId: "joiner-1",
            error: .addMemberFailed
        )
        let malicious = JoinRequestDMOutcome.malicious(
            dmConversationId: "dm-1",
            senderInboxId: "joiner-1",
            error: .invalidSignature
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: benign) == nil)
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: malicious) == nil)
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: .noJoinRequest) == nil)
    }

    @Test("Nil cursor clamps to the 24h window instead of sweeping all history")
    func nilCursorClampsToWindow() {
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: nil, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Recent cursor passes through unchanged")
    func recentCursorUnchanged() {
        let recent = now.addingTimeInterval(-300)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: recent, now: now)
        #expect(effective == recent)
    }

    @Test("Cursor older than the window clamps to the window")
    func ancientCursorClamps() {
        let ancient = now.addingTimeInterval(-90 * day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: ancient, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Cursor exactly at the window boundary is preserved")
    func boundaryCursorPreserved() {
        let boundary = now.addingTimeInterval(-day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: boundary, now: now)
        #expect(effective == boundary)
    }
}
