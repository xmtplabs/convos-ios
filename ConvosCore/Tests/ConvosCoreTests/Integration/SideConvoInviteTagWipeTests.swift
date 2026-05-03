@testable import ConvosCore
import ConvosAppData
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// Reproduces the side-convo invite-tag wipe observed in
/// `convos-logs-BD663A2F` and `convos-logs-65D971ED`:
///
/// - Creator creates a side convo and stamps an invite tag (`YFqUSVvgLD`
///   in the captured logs).
/// - A member added to the side convo immediately runs a metadata write
///   (`MyProfileWriter.updateProfile` on join). That write goes through
///   `XMTPGroup.atomicUpdateMetadata`, which reads `appData()` first.
/// - When that read returns an empty / parse-failed value (silent
///   fallback in `ConvosAppData.parseAppData` →
///   `XMTPGroup.currentCustomMetadata`), the closure modifies an empty
///   `ConversationCustomMetadata`, and the guard at
///   `XMTPGroup+CustomMetadata.swift:339` does not fire because
///   `beforeMetadata.tag` itself was empty. The commit is published with
///   `metadata.tag = ""`, wiping the on-wire tag for everyone.
/// - Subsequent join attempts using the original invite URL fail with
///   `InviteJoinError.conversationExpired` because the side convo's
///   current tag no longer matches the tag baked into the URL.
///
/// This test forces the empty-`appData` precondition deterministically
/// (by writing empty appData from the creator and then syncing the
/// member) and asserts the **correct** behavior: the member's
/// metadata write must not wipe the on-wire tag. With the current
/// code this assertion fails, so the test reproduces the bug; once the
/// `atomicUpdateMetadata` guard is strengthened (cross-check the local
/// DB tag and refuse to commit a tag-clear) the test passes.
@Suite("Side Convo Invite Tag Wipe Tests", .serialized)
struct SideConvoInviteTagWipeTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("Member's metadata write must not wipe the side convo invite tag")
    func memberMetadataWriteMustNotWipeInviteTag() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        // Creator (A) creates the side convo and stamps an invite tag.
        let groupA = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Side Convo"
        )
        try await groupA.ensureInviteTag()
        let originalTag = try groupA.inviteTag
        #expect(!originalTag.isEmpty, "ensureInviteTag must produce a non-empty tag")

        // Member (B) syncs and resolves the same group.
        try await clientB.conversations.sync()
        let groupB = try #require(
            try clientB.conversations.listGroups().first { $0.id == groupA.id }
        )
        try await groupB.sync()

        // Reproduce the in-the-wild precondition (BD663A2F log: 8dbded's
        // appData shrunk from 303 → 24 bytes after a peer commit). We
        // force the on-wire appData to empty — this is the same state
        // `atomicUpdateMetadata` would observe whenever
        // `parseAppData` silently fails (decompression error, transient
        // MLS state lag right after a welcome, corrupt commit) and falls
        // back to `ConversationCustomMetadata()`.
        try await groupA.updateAppData(appData: "")
        try await clientB.conversations.sync()
        try await groupB.sync()

        // Member runs a benign metadata write — exactly what
        // `MyProfileWriter.updateProfile` does on join. With the bug
        // present this commit publishes empty-tag metadata, finalizing
        // the wipe; every subsequent join with `originalTag` will fail
        // with `InviteJoinError.conversationExpired`.
        try await groupB.updateProfile(
            DBMemberProfile(
                conversationId: groupB.id,
                inboxId: clientB.inboxID,
                name: "Bob",
                avatar: nil
            )
        )

        // Sync the creator and re-read the on-wire tag.
        try await clientA.conversations.sync()
        try await groupA.sync()
        let tagAfterMemberWrite = try groupA.inviteTag

        // After the fix this assertion passes (the member's write is
        // rejected before it can commit empty-tag metadata). With the
        // current code the assertion fails — `tagAfterMemberWrite` is
        // empty, reproducing the bug.
        #expect(
            tagAfterMemberWrite == originalTag,
            """
            Side convo invite tag was wiped by a member's metadata write.
            originalTag=\(originalTag)
            tagAfterMemberWrite=\(tagAfterMemberWrite)
            Subsequent joins with originalTag will be rejected as
            InviteJoinError.conversationExpired (see investigation logs
            convos-logs-BD663A2F).
            """
        )

        try? await fixtures.cleanup()
    }

    /// Direct unit-style coverage of the same defect at the
    /// `atomicUpdateMetadata` level — no second client required. Reads a
    /// group whose `appData` was just emptied, runs a metadata write
    /// (e.g. `updateProfile`) on the local handle, and asserts the
    /// existing non-empty tag survives. Today this fails for the same
    /// reason the multi-client test fails: the empty-tag guard at
    /// `XMTPGroup+CustomMetadata.swift:339` only fires when
    /// `beforeMetadata.tag` was already non-empty in the read.
    @Test("Local metadata write on a group whose appData is empty must not wipe a previously-stamped tag")
    func localMetadataWriteOnEmptyAppDataMustNotWipePreviouslyStampedTag() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Side Convo"
        )
        try await group.ensureInviteTag()
        let originalTag = try group.inviteTag
        #expect(!originalTag.isEmpty)

        // Force `appData` empty from the same client. `atomicUpdateMetadata`
        // re-reads on every attempt; subsequent writes will see an empty
        // `beforeMetadata` and the guard at line 339 will not catch the
        // wipe.
        try await group.updateAppData(appData: "")

        try await group.updateProfile(
            DBMemberProfile(
                conversationId: group.id,
                inboxId: clientA.inboxID,
                name: "Alice",
                avatar: nil
            )
        )

        let tagAfterWrite = try group.inviteTag
        #expect(
            tagAfterWrite == originalTag,
            """
            atomicUpdateMetadata committed an empty-tag write because the
            stale `appData` read returned an empty `ConversationCustomMetadata`.
            originalTag=\(originalTag) tagAfterWrite=\(tagAfterWrite)
            """
        )

        try? await fixtures.cleanup()
    }
}
