@testable import ConvosCore
import Foundation
import Testing

@Suite("Phase 2.9 member-name override precedence")
struct MemberNameOverrideTests {
    private static func profile(
        inboxId: String,
        name: String?
    ) -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: "convo-1",
            name: name,
            avatar: nil
        )
    }

    private static func member(
        inboxId: String,
        name: String?,
        isCurrentUser: Bool = false,
        role: MemberRole = .member
    ) -> ConversationMember {
        ConversationMember(
            profile: profile(inboxId: inboxId, name: name),
            role: role,
            isCurrentUser: isCurrentUser
        )
    }

    // MARK: - Profile.formattedNamesString(memberNameOverride:)

    @Test("Per-conversation profile name takes precedence over override")
    func testProfileNameWins() {
        let withName = Self.profile(inboxId: "inbox-1", name: "Alice")
        let result = [withName].formattedNamesString { _ in "OverrideName" }
        #expect(result == "Alice")
    }

    @Test("Override fills in for missing profile name")
    func testOverrideFillsMissingName() {
        let p = Self.profile(inboxId: "inbox-1", name: nil)
        let result = [p].formattedNamesString { inboxId in
            inboxId == "inbox-1" ? "Alice" : nil
        }
        #expect(result == "Alice")
    }

    @Test("Empty profile name is treated as missing for override purposes")
    func testEmptyProfileNameTriggersOverride() {
        let p = Self.profile(inboxId: "inbox-1", name: "")
        let result = [p].formattedNamesString { _ in "Alice" }
        #expect(result == "Alice")
    }

    @Test("No profile name + no override → Somebody")
    func testNoNameNoOverrideFallsBackToSomebody() {
        let p = Self.profile(inboxId: "inbox-1", name: nil)
        let result = [p].formattedNamesString { _ in nil }
        #expect(result == "Somebody")
    }

    @Test("Override returning empty string is treated as no override")
    func testEmptyOverrideTreatedAsNoOverride() {
        let p = Self.profile(inboxId: "inbox-1", name: nil)
        let result = [p].formattedNamesString { _ in "" }
        #expect(result == "Somebody")
    }

    @Test("Mixed: some profiles named, some via override")
    func testMixedResolution() {
        let profiles: [Profile] = [
            Self.profile(inboxId: "alice", name: "Alice"),
            Self.profile(inboxId: "bob", name: nil),
        ]
        let result = profiles.formattedNamesString { inboxId in
            inboxId == "bob" ? "Bob" : nil
        }
        #expect(result.contains("Alice"))
        #expect(result.contains("Bob"))
        #expect(!result.contains("Somebody"))
    }

    @Test("Legacy formattedNamesString (no override) still emits Somebody for nameless")
    func testLegacyFormattedNamesStringUnchanged() {
        let p = Self.profile(inboxId: "inbox-1", name: nil)
        #expect([p].formattedNamesString == "Somebody")
    }

    // MARK: - ConversationUpdate.summary(memberNameOverride:)

    @Test("summary uses override for joined member without profile name")
    func testJoinSummaryUsesOverride() {
        let creator = Self.member(inboxId: "inviter", name: "InviterName")
        let joiner = Self.member(inboxId: "joiner", name: nil)
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [joiner],
            removedMembers: [],
            metadataChanges: []
        )
        let result = update.summary { inboxId in
            inboxId == "joiner" ? "Alice" : nil
        }
        #expect(result == "Alice joined · Invited by InviterName")
    }

    @Test("summary with no override returns Somebody for nameless joiner")
    func testJoinSummaryFallsBackToSomebody() {
        let creator = Self.member(inboxId: "inviter", name: "Inviter")
        let joiner = Self.member(inboxId: "joiner", name: nil)
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [joiner],
            removedMembers: [],
            metadataChanges: []
        )
        let result = update.summary { _ in nil }
        #expect(result == "Somebody joined · Invited by Inviter")
    }

    @Test("Profile name wins over override in summary")
    func testProfileNameWinsInSummary() {
        let creator = Self.member(inboxId: "inviter", name: "Inviter")
        let joiner = Self.member(inboxId: "joiner", name: "JoinerProfileName")
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [joiner],
            removedMembers: [],
            metadataChanges: []
        )
        let result = update.summary { _ in "ContactNameOverride" }
        #expect(result.contains("JoinerProfileName"))
        #expect(!result.contains("ContactNameOverride"))
    }

    @Test("Removed member uses override")
    func testRemovedMemberSummaryUsesOverride() {
        let creator = Self.member(inboxId: "admin", name: "Admin")
        let removed = Self.member(inboxId: "removed", name: nil)
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [],
            removedMembers: [removed],
            metadataChanges: []
        )
        let result = update.summary { inboxId in
            inboxId == "removed" ? "Bob" : nil
        }
        #expect(result == "Bob left")
    }

    @Test("Self-joiner shows You regardless of override")
    func testSelfJoinerStillShowsYou() {
        let creator = Self.member(inboxId: "other", name: "Other")
        let selfMember = Self.member(inboxId: "me", name: "MyName", isCurrentUser: true)
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [selfMember],
            removedMembers: [],
            metadataChanges: []
        )
        let result = update.summary { _ in "ContactName" }
        #expect(result.hasPrefix("You joined"))
    }

    @Test("Legacy summary (no override) preserves existing 'Somebody' behavior")
    func testLegacySummaryUnchanged() {
        let creator = Self.member(inboxId: "inviter", name: "Inviter")
        let joiner = Self.member(inboxId: "joiner", name: nil)
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [joiner],
            removedMembers: [],
            metadataChanges: []
        )
        // The unparameterized `summary` getter should still produce
        // "Somebody joined …" — Phase 2.9 is opt-in per call site.
        #expect(update.summary == "Somebody joined · Invited by Inviter")
    }
}
