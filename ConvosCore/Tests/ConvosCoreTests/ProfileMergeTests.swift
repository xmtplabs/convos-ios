@testable import ConvosCore
import Foundation
import Testing

@Suite("Profile merge - identity")
struct ProfileMergeIdentityTests {
    private let t1 = Date(timeIntervalSince1970: 100)
    private let t2 = Date(timeIntervalSince1970: 200)

    @Test("creates a new profile from no existing row, dropping a blank name")
    func createsNew() {
        let blank = ProfileMerge.mergeIdentity(
            existing: nil, inboxId: "i", incoming: IncomingIdentity(name: "  "),
            source: .profileUpdate, sentAt: t1
        )
        #expect(blank.name == nil)
        #expect(blank.profileSource == .profileUpdate)
        #expect(blank.updatedAt == t1)

        let named = ProfileMerge.mergeIdentity(
            existing: nil, inboxId: "i", incoming: IncomingIdentity(name: "Alice"),
            source: .contact, sentAt: t1
        )
        #expect(named.name == "Alice")
        #expect(named.profileSource == .contact)
    }

    @Test("an empty incoming name never clears a populated name")
    func nameNeverCleared() {
        let existing = DBProfile(inboxId: "i", name: "Alice", profileSource: .profileUpdate, updatedAt: t1)
        let merged = ProfileMerge.mergeIdentity(
            existing: existing, inboxId: "i", incoming: IncomingIdentity(name: ""),
            source: .profileUpdate, sentAt: t2
        )
        #expect(merged.name == "Alice")
        #expect(merged.updatedAt == t2)
    }

    @Test("higher source overwrites a lower-source value")
    func higherSourceWins() {
        let existing = DBProfile(inboxId: "i", name: "Old", profileSource: .contact, updatedAt: t1)
        let merged = ProfileMerge.mergeIdentity(
            existing: existing, inboxId: "i", incoming: IncomingIdentity(name: "New"),
            source: .profileUpdate, sentAt: t1
        )
        #expect(merged.name == "New")
        #expect(merged.profileSource == .profileUpdate)
    }

    @Test("within the same source, newer wins and older is dropped")
    func recencyWithinSource() {
        let existing = DBProfile(inboxId: "i", name: "A", profileSource: .profileUpdate, updatedAt: t1)
        let newer = ProfileMerge.mergeIdentity(
            existing: existing, inboxId: "i", incoming: IncomingIdentity(name: "B"),
            source: .profileUpdate, sentAt: t2
        )
        #expect(newer.name == "B")

        let existing2 = DBProfile(inboxId: "i", name: "B", profileSource: .profileUpdate, updatedAt: t2)
        let older = ProfileMerge.mergeIdentity(
            existing: existing2, inboxId: "i", incoming: IncomingIdentity(name: "A"),
            source: .profileUpdate, sentAt: t1
        )
        #expect(older.name == "B")
        #expect(older.updatedAt == t2)
    }

    @Test("a lower source fills a blank name without changing provenance")
    func lowerSourceFillsBlank() {
        let existing = DBProfile(inboxId: "i", name: nil, profileSource: .profileUpdate, updatedAt: t2)
        let merged = ProfileMerge.mergeIdentity(
            existing: existing, inboxId: "i", incoming: IncomingIdentity(name: "Filled"),
            source: .contact, sentAt: t1
        )
        #expect(merged.name == "Filled")
        #expect(merged.profileSource == .profileUpdate)
        #expect(merged.updatedAt == t2)
    }

    @Test("a verified assistant kind is never downgraded to generic agent")
    func preservesVerifiedKind() {
        let existing = DBProfile(inboxId: "i", memberKind: .verifiedConvos, profileSource: .profileUpdate, updatedAt: t1)
        let downgrade = ProfileMerge.mergeIdentity(
            existing: existing, inboxId: "i", incoming: IncomingIdentity(memberKind: .agent),
            source: .profileUpdate, sentAt: t2
        )
        #expect(downgrade.memberKind == .verifiedConvos)

        let upgradeFrom = DBProfile(inboxId: "i", memberKind: .agent, profileSource: .profileUpdate, updatedAt: t1)
        let upgrade = ProfileMerge.mergeIdentity(
            existing: upgradeFrom, inboxId: "i", incoming: IncomingIdentity(memberKind: .verifiedConvos),
            source: .profileUpdate, sentAt: t2
        )
        #expect(upgrade.memberKind == .verifiedConvos)
    }
}

@Suite("Profile merge - avatar")
struct ProfileMergeAvatarTests {
    private let t1 = Date(timeIntervalSince1970: 100)
    private let t2 = Date(timeIntervalSince1970: 200)
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    private func setAvatar(_ url: String) -> IncomingAvatar {
        .set(url: url, salt: salt, nonce: nonce, key: key)
    }

    @Test("silent leaves the slot untouched")
    func silentLeavesSlot() {
        let existing = DBProfileAvatar(inboxId: "i", conversationId: "c", url: "x", profileSource: .profileUpdate, updatedAt: t1)
        let merged = ProfileMerge.mergeAvatar(
            existing: existing, inboxId: "i", conversationId: "c", incoming: .silent,
            source: .profileUpdate, sentAt: t2
        )
        #expect(merged?.url == "x")
        let none = ProfileMerge.mergeAvatar(
            existing: nil, inboxId: "i", conversationId: "c", incoming: .silent,
            source: .profileUpdate, sentAt: t2
        )
        #expect(none == nil)
    }

    @Test("set creates a slot when none exists")
    func setCreatesSlot() {
        let merged = ProfileMerge.mergeAvatar(
            existing: nil, inboxId: "i", conversationId: "c", incoming: setAvatar("u"),
            source: .profileUpdate, sentAt: t1
        )
        #expect(merged?.url == "u")
        #expect(merged?.hasValidEncryptedAvatar == true)
        #expect(merged?.profileSource == .profileUpdate)
    }

    @Test("explicit clear records a tombstone that survives a later silent")
    func explicitClearTombstones() {
        let cleared = ProfileMerge.mergeAvatar(
            existing: DBProfileAvatar(inboxId: "i", conversationId: "c", url: "old", profileSource: .profileUpdate, updatedAt: t1),
            inboxId: "i", conversationId: "c", incoming: .explicitClear,
            source: .profileUpdate, sentAt: t2
        )
        #expect(cleared?.url == nil)
        #expect(cleared?.updatedAt == t2)

        let afterSilent = ProfileMerge.mergeAvatar(
            existing: cleared, inboxId: "i", conversationId: "c", incoming: .silent,
            source: .profileUpdate, sentAt: t2
        )
        #expect(afterSilent?.url == nil)
    }

    @Test("a lower or older event never overrides or resurrects a slot")
    func lowerOrOlderIgnored() {
        // Lower-source set does not override a higher-source value.
        let high = DBProfileAvatar(inboxId: "i", conversationId: "c", url: "keep", profileSource: .profileUpdate, updatedAt: t1)
        let lowerSet = ProfileMerge.mergeAvatar(
            existing: high, inboxId: "i", conversationId: "c", incoming: setAvatar("ignored"),
            source: .profileSnapshot, sentAt: t2
        )
        #expect(lowerSet?.url == "keep")

        // Lower-source set does not resurrect a tombstone.
        let tombstone = DBProfileAvatar(inboxId: "i", conversationId: "c", url: nil, profileSource: .profileUpdate, updatedAt: t2)
        let resurrect = ProfileMerge.mergeAvatar(
            existing: tombstone, inboxId: "i", conversationId: "c", incoming: setAvatar("ignored"),
            source: .contact, sentAt: t1
        )
        #expect(resurrect?.url == nil)
    }

    @Test("newer set within the same source replaces an older value")
    func newerSetReplaces() {
        let existing = DBProfileAvatar(inboxId: "i", conversationId: "c", url: "old", profileSource: .profileUpdate, updatedAt: t1)
        let merged = ProfileMerge.mergeAvatar(
            existing: existing, inboxId: "i", conversationId: "c", incoming: setAvatar("new"),
            source: .profileUpdate, sentAt: t2
        )
        #expect(merged?.url == "new")
    }
}

@Suite("SelfProfileEdit")
struct SelfProfileEditTests {
    private let t1 = Date(timeIntervalSince1970: 1)
    private let t2 = Date(timeIntervalSince1970: 2)

    @Test("keep leaves a field unchanged; set replaces it")
    func appliesPartialEdit() {
        let base = DBSelfProfile(inboxId: "me", name: "Old", metadata: ["k": .string("v")], updatedAt: t1)

        let nameOnly = SelfProfileEdit(name: .set("New")).applied(to: base, updatedAt: t2)
        #expect(nameOnly.name == "New")
        #expect(nameOnly.metadata?["k"]?.stringValue == "v")
        #expect(nameOnly.updatedAt == t2)

        let metadataOnly = SelfProfileEdit(metadata: .set(nil)).applied(to: base, updatedAt: t2)
        #expect(metadataOnly.name == "Old")
        #expect(metadataOnly.metadata == nil)
    }
}
