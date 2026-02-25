@testable import ConvosInvites
@testable import ConvosInvitesCore
import Foundation
import Testing

// Note: Full integration tests require a running XMTP node.
// These tests verify the basic structure and types compile correctly.

@Suite("InviteCoordinator Tests")
struct InviteCoordinatorTests {
    @Test("InviteOptions defaults")
    func inviteOptionsDefaults() {
        let options = InviteOptions()

        #expect(options.name == nil)
        #expect(options.description == nil)
        #expect(options.imageURL == nil)
        #expect(options.expiresAt == nil)
        #expect(options.singleUse == false)
        #expect(options.includePublicPreview == true)
    }

    @Test("InviteOptions expiring helper")
    func inviteOptionsExpiring() {
        let options = InviteOptions.expiring(after: 3600, singleUse: true)

        #expect(options.expiresAt != nil)
        #expect(options.singleUse == true)

        // Should expire in roughly 1 hour
        if let expiresAt = options.expiresAt {
            let interval = expiresAt.timeIntervalSinceNow
            #expect(interval > 3590 && interval < 3610)
        }
    }

    @Test("JoinResult initialization")
    func joinResultInit() {
        let result = JoinResult(
            conversationId: "conv-123",
            joinerInboxId: "inbox-456",
            conversationName: "Test Group"
        )

        #expect(result.conversationId == "conv-123")
        #expect(result.joinerInboxId == "inbox-456")
        #expect(result.conversationName == "Test Group")
    }

    @Test("InviteJoinError encoding")
    func inviteJoinErrorEncoding() throws {
        let error = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "abc123",
            timestamp: Date(timeIntervalSince1970: 1000000)
        )

        let encoded = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(InviteJoinError.self, from: encoded)

        #expect(decoded.errorType == .conversationExpired)
        #expect(decoded.inviteTag == "abc123")
    }
}
