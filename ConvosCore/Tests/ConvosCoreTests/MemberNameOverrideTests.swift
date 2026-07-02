@testable import ConvosCore
import Foundation
import Testing

@Suite("Member-name override precedence")
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

    @Test("Override (contact name) wins over per-conversation profile name")
    func testOverrideWinsOverProfileName() {
        let withName = Self.profile(inboxId: "inbox-1", name: "ProfileName")
        let result = [withName].formattedNamesString { _ in "ContactName" }
        #expect(result == "ContactName")
    }

    @Test("Profile name is used when override returns nil")
    func testProfileNameWhenNoOverride() {
        let p = Self.profile(inboxId: "inbox-1", name: "Alice")
        let result = [p].formattedNamesString { _ in nil }
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

    @Test("Empty override falls through to profile name")
    func testEmptyOverrideFallsThroughToProfileName() {
        let p = Self.profile(inboxId: "inbox-1", name: "Alice")
        let result = [p].formattedNamesString { _ in "" }
        #expect(result == "Alice")
    }

    @Test("No profile name + no override → Somebody")
    func testNoNameNoOverrideFallsBackToSomebody() {
        let p = Self.profile(inboxId: "inbox-1", name: nil)
        let result = [p].formattedNamesString { _ in nil }
        #expect(result == "Somebody")
    }

    @Test("Empty override + no profile name → Somebody")
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

    @Test("Override (contact name) wins over profile name in summary")
    func testOverrideWinsInSummary() {
        let creator = Self.member(inboxId: "inviter", name: "Inviter")
        let joiner = Self.member(inboxId: "joiner", name: "JoinerProfileName")
        let update = ConversationUpdate(
            creator: creator,
            addedMembers: [joiner],
            removedMembers: [],
            metadataChanges: []
        )
        let result = update.summary { inboxId in
            inboxId == "joiner" ? "ContactNameOverride" : nil
        }
        #expect(result.contains("ContactNameOverride"))
        #expect(!result.contains("JoinerProfileName"))
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
        #expect(result == "Bob left · Removed by Admin")
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
        // "Somebody joined" - the override is opt-in per call site.
        #expect(update.summary == "Somebody joined · Invited by Inviter")
    }

    // MARK: - Conversation.computedDisplayName(memberNameOverride:)

    @Test("Explicit conversation name is returned verbatim, override ignored")
    func testExplicitConversationNameIgnoresOverride() {
        let alice = Self.member(inboxId: "alice", name: "AliceProfile")
        let me = Self.member(inboxId: "me", name: "Me", isCurrentUser: true)
        let conversation = Conversation.mock(name: "Custom Name", members: [me, alice])
        let result = conversation.computedDisplayName { _ in "AliceContact" }
        #expect(result == "Custom Name")
    }

    @Test("DM title uses contact-name override over per-conversation profile name")
    func testDMUsesContactNameOverride() {
        let alice = Self.member(inboxId: "alice", name: "AliceProfile")
        let me = Self.member(inboxId: "me", name: "Me", isCurrentUser: true)
        let conversation = Conversation.mock(name: nil, members: [me, alice])
        let result = conversation.computedDisplayName { inboxId in
            inboxId == "alice" ? "AliceContact" : nil
        }
        #expect(result == "AliceContact")
    }

    @Test("Unnamed group title uses contact-name override over profile names")
    func testUnnamedGroupUsesContactName() {
        let alice = Self.member(inboxId: "alice", name: "AliceProfile")
        let bob = Self.member(inboxId: "bob", name: "BobProfile")
        let me = Self.member(inboxId: "me", name: "Me", isCurrentUser: true)
        let conversation = Conversation.mock(name: nil, members: [me, alice, bob])
        let result = conversation.computedDisplayName { inboxId in
            switch inboxId {
            case "alice": return "AliceContact"
            case "bob": return "BobContact"
            default: return nil
            }
        }
        #expect(result.contains("AliceContact"))
        #expect(result.contains("BobContact"))
        #expect(!result.contains("AliceProfile"))
        #expect(!result.contains("BobProfile"))
    }

    @Test("Unnamed group title uses contact-name even for nameless members")
    func testUnnamedGroupContactNameForNamelessMember() {
        let nameless = Self.member(inboxId: "alice", name: nil)
        let bob = Self.member(inboxId: "bob", name: "Bob")
        let me = Self.member(inboxId: "me", name: "Me", isCurrentUser: true)
        let conversation = Conversation.mock(name: nil, members: [me, nameless, bob])
        let result = conversation.computedDisplayName { inboxId in
            inboxId == "alice" ? "AliceContact" : nil
        }
        #expect(result.contains("AliceContact"))
        #expect(!result.contains("Somebody"))
    }

    // MARK: - ConversationMember.displayName(contactNameFallback:)
    // Fallback-only variant used by message-derived surfaces (in-chat bubble,
    // conversation-list preview). The per-conversation name wins; the contact
    // name only fills an empty name. Unlike the override variant, it can never
    // replace a name that already renders correctly.

    @Test("Fallback: the per-conversation name wins over the contact name")
    func testFallbackProfileNameWins() {
        let member = Self.member(inboxId: "alice", name: "AliceProfile")
        let result = member.displayName(contactNameFallback: { _ in "AliceContact" })
        #expect(result == "AliceProfile")
    }

    @Test("Fallback: the contact name fills an empty per-conversation name")
    func testFallbackFillsEmptyName() {
        let member = Self.member(inboxId: "alice", name: nil)
        let result = member.displayName(contactNameFallback: { inboxId in
            inboxId == "alice" ? "AliceContact" : nil
        })
        #expect(result == "AliceContact")
    }

    @Test("Fallback: empty name and no contact still renders Somebody")
    func testFallbackNoNameNoContactSomebody() {
        let member = Self.member(inboxId: "alice", name: nil)
        let result = member.displayName(contactNameFallback: { _ in nil })
        #expect(result == "Somebody")
    }

    @Test("Fallback: an empty contact name is ignored")
    func testFallbackEmptyContactIgnored() {
        let member = Self.member(inboxId: "alice", name: nil)
        let result = member.displayName(contactNameFallback: { _ in "" })
        #expect(result == "Somebody")
    }
}
