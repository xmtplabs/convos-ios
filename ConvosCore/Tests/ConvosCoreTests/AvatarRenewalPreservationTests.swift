@testable import ConvosCore
import Foundation
import Testing

@Suite("Avatar Renewal Preservation Tests")
struct AvatarRenewalPreservationTests {
    @Test("Preserves avatarLastRenewed when avatar URL is unchanged")
    func testPreservesLastRenewedWhenAvatarUnchanged() {
        let renewedAt = Date().addingTimeInterval(-3600)
        let existing = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Existing",
            avatar: "https://example.com/a.bin",
            avatarLastRenewed: renewedAt
        )
        let incoming = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Incoming",
            avatar: "https://example.com/a.bin",
            avatarLastRenewed: nil
        )

        let result = ConversationWriter.preservingAvatarLastRenewed(
            incomingProfile: incoming,
            existingProfile: existing
        )

        #expect(result.avatarLastRenewed == renewedAt)
    }

    @Test("Clears avatarLastRenewed when avatar URL changes")
    func testClearsLastRenewedWhenAvatarChanges() {
        let existing = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Existing",
            avatar: "https://example.com/a.bin",
            avatarLastRenewed: Date()
        )
        let incoming = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Incoming",
            avatar: "https://example.com/b.bin",
            avatarLastRenewed: Date()
        )

        let result = ConversationWriter.preservingAvatarLastRenewed(
            incomingProfile: incoming,
            existingProfile: existing
        )

        #expect(result.avatarLastRenewed == nil)
    }

    @Test("Clears avatarLastRenewed when incoming avatar is nil")
    func testClearsLastRenewedWhenIncomingAvatarNil() {
        let existing = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Existing",
            avatar: "https://example.com/a.bin",
            avatarLastRenewed: Date()
        )
        let incoming = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Incoming",
            avatar: nil,
            avatarLastRenewed: Date()
        )

        let result = ConversationWriter.preservingAvatarLastRenewed(
            incomingProfile: incoming,
            existingProfile: existing
        )

        #expect(result.avatarLastRenewed == nil)
    }
}
