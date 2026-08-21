import ConvosAppData
@testable import ConvosCore
import Foundation
import Testing

/// Pure transplant-rule tests: each updater carries only its own domain's
/// sub-field from the persisted snapshot into the fresh network blob.
@Suite("AppData updaters")
struct AppDataUpdaterTests {
    private let conversationId = "conv-1"

    private func merge(
        _ updater: any AppDataUpdater,
        current: ConversationCustomMetadata,
        snapshot: ConversationCustomMetadata,
        scopeKey: String? = nil
    ) -> ConversationCustomMetadata {
        updater.onAppDataMerge(
            conversationId: conversationId,
            scopeKey: scopeKey,
            current: current,
            previousChanged: snapshot
        )
    }

    @Test("Invite tag transplants over the network value and carries other fields")
    func inviteTagTransplant() {
        var current = ConversationCustomMetadata()
        current.tag = "oldTag0000"
        current.spaceURL = "https://space.example"
        var snapshot = ConversationCustomMetadata()
        snapshot.tag = "newTag0000"

        let merged = merge(InviteTagUpdater(), current: current, snapshot: snapshot)
        #expect(merged.tag == "newTag0000")
        #expect(merged.spaceURL == "https://space.example")
    }

    @Test("Invite tag with an empty snapshot never clears the network tag")
    func inviteTagEmptySnapshotIsNoOp() {
        var current = ConversationCustomMetadata()
        current.tag = "oldTag0000"

        let merged = merge(InviteTagUpdater(), current: current, snapshot: ConversationCustomMetadata())
        #expect(merged.tag == "oldTag0000")
    }

    @Test("Profile transplants only the scoped inbox's entry")
    func profileScopedTransplant() throws {
        let mine = Data(repeating: 0xAA, count: 16)
        let theirs = Data(repeating: 0xBB, count: 16)

        var myEntry = ConversationProfile()
        myEntry.inboxID = mine
        myEntry.name = "New Name"
        var theirCurrentEntry = ConversationProfile()
        theirCurrentEntry.inboxID = theirs
        theirCurrentEntry.name = "Peer"

        var current = ConversationCustomMetadata()
        current.profiles = [theirCurrentEntry]
        var snapshot = ConversationCustomMetadata()
        var theirStaleEntry = theirCurrentEntry
        theirStaleEntry.name = "Stale Peer"
        snapshot.profiles = [theirStaleEntry, myEntry]

        let merged = merge(ProfileUpdater(), current: current, snapshot: snapshot, scopeKey: mine.toHexString())
        #expect(merged.findProfile(inboxId: mine.toHexString())?.name == "New Name")
        #expect(merged.findProfile(inboxId: theirs.toHexString())?.name == "Peer")
    }

    @Test("Profile without a scope key is a no-op")
    func profileNoScopeKey() {
        var snapshot = ConversationCustomMetadata()
        var entry = ConversationProfile()
        entry.inboxID = Data(repeating: 0xAA, count: 16)
        entry.name = "New Name"
        snapshot.profiles = [entry]

        let merged = merge(ProfileUpdater(), current: ConversationCustomMetadata(), snapshot: snapshot)
        #expect(merged.profiles.isEmpty)
    }

    @Test("Participation and expiry transplant when the snapshot carries them")
    func participationAndExpiry() {
        var current = ConversationCustomMetadata()
        current.tag = "keptTag000"
        var snapshot = ConversationCustomMetadata()
        snapshot.participationMode = .mentionsOnly
        snapshot.expiresAtUnix = 1_234

        let withMode = merge(ParticipationUpdater(), current: current, snapshot: snapshot)
        #expect(withMode.participationMode == .mentionsOnly)
        #expect(withMode.tag == "keptTag000")
        #expect(!withMode.hasExpiresAtUnix)

        let withExpiry = merge(ExpiryUpdater(), current: current, snapshot: snapshot)
        #expect(withExpiry.expiresAtUnix == 1_234)
        #expect(!withExpiry.hasParticipationMode)

        let untouched = merge(ParticipationUpdater(), current: current, snapshot: ConversationCustomMetadata())
        #expect(!untouched.hasParticipationMode)
    }

    @Test("Emoji is ensure-if-absent: a peer's network value wins")
    func emojiPeerWins() {
        var snapshot = ConversationCustomMetadata()
        snapshot.emoji = "🦊"

        let ontoEmpty = merge(EmojiUpdater(), current: ConversationCustomMetadata(), snapshot: snapshot)
        #expect(ontoEmpty.emoji == "🦊")

        var currentWithEmoji = ConversationCustomMetadata()
        currentWithEmoji.emoji = "🐙"
        let ontoSet = merge(EmojiUpdater(), current: currentWithEmoji, snapshot: snapshot)
        #expect(ontoSet.emoji == "🐙")
    }

    @Test("Agent DM marker is write-once: an existing network marker wins")
    func agentDmWriteOnce() {
        var snapshot = ConversationCustomMetadata()
        snapshot.markAgentDm(originConversationId: Data([0x01]))

        let ontoEmpty = merge(AgentDmUpdater(), current: ConversationCustomMetadata(), snapshot: snapshot)
        #expect(ontoEmpty.hasAgentDm)
        #expect(ontoEmpty.agentDm.originConversationID == Data([0x01]))

        var currentMarked = ConversationCustomMetadata()
        currentMarked.markAgentDm(originConversationId: Data([0x02]))
        let ontoMarked = merge(AgentDmUpdater(), current: currentMarked, snapshot: snapshot)
        #expect(ontoMarked.agentDm.originConversationID == Data([0x02]))
    }

    @Test("Legacy image cleanup clears whenever the network still carries a ref")
    func legacyImageCleanup() {
        var ref = EncryptedImageRef()
        ref.url = "https://img.example/x.jpg"
        ref.salt = Data(repeating: 0x01, count: 16)
        ref.nonce = Data(repeating: 0x02, count: 12)
        var current = ConversationCustomMetadata()
        current.encryptedGroupImage = ref
        current.tag = "keptTag000"

        let merged = merge(LegacyImageCleanupUpdater(), current: current, snapshot: ConversationCustomMetadata())
        #expect(!merged.hasEncryptedGroupImage)
        #expect(merged.tag == "keptTag000")

        let idempotent = merge(LegacyImageCleanupUpdater(), current: merged, snapshot: ConversationCustomMetadata())
        #expect(idempotent == merged)
    }

    @Test("Standard registry covers every domain")
    func standardRegistry() {
        let registry: [AppDataDomain: any AppDataUpdater] = .standard
        #expect(Set(registry.keys) == Set(AppDataDomain.allCases))
        for (domain, updater) in registry {
            #expect(updater.domain == domain)
        }
    }

    @Test("Named mutations are idempotent")
    func mutationIdempotence() {
        var metadata = ConversationCustomMetadata()
        metadata.ensureTag("firstTag00")
        metadata.ensureTag("secondTag0")
        #expect(metadata.tag == "firstTag00")

        metadata.ensureEmoji("🦊")
        metadata.ensureEmoji("🐙")
        #expect(metadata.emoji == "🦊")
    }

    @Test("Invite tag generation produces valid tags")
    func inviteTagGeneration() throws {
        let tag = try InviteTag.generate()
        #expect(InviteTag.isValid(tag))
        #expect(!InviteTag.isValid("short"))
        #expect(!InviteTag.isValid("has spaces!"))
        #expect(throws: (any Error).self) {
            try InviteTag.generate(length: 0)
        }
    }
}
