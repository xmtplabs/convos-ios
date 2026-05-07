@testable import ConvosCore
import Foundation
import Testing

@Suite("InboundConversationFilter Tests", .serialized)
struct InboundConversationFilterTests {
    private static let creator: String = "creator-1"
    private static let me: String = "me"

    @Test(".allowed consent always delivers (no contact gate needed)")
    func testAllowedDelivers() {
        let repo = MockContactsRepository(contacts: [])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .allowed,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(decision == .deliver)
    }

    @Test("Self-creator delivers regardless of contact status")
    func testSelfCreatorDelivers() {
        let repo = MockContactsRepository(contacts: [])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.me,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(decision == .deliver)
    }

    @Test(".unknown + outgoing join request → deliver (legacy invite-flow)")
    func testInviteFlowHandshakeDelivers() {
        let repo = MockContactsRepository(contacts: [])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: true
        )
        #expect(decision == .deliver)
    }

    @Test(".unknown + sender is contact → deliver (new contact-list path)")
    func testKnownContactDelivers() {
        let repo = MockContactsRepository(contacts: [.mock(inboxId: Self.creator)])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(decision == .deliver)
    }

    @Test(".unknown + stranger → quarantine")
    func testStrangerQuarantines() {
        let repo = MockContactsRepository(contacts: [])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(decision == .quarantine)
    }

    @Test("Blocked contact quarantines on .unknown so unblocking later can restore access")
    func testBlockedQuarantinesOnUnknown() {
        let repo = MockContactsRepository(
            contacts: [.mock(inboxId: Self.creator, isBlocked: true)]
        )
        let filter = InboundConversationFilter(contactsRepository: repo)

        let unknownDecision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: true
        )
        #expect(unknownDecision == .quarantine)
    }

    @Test(".allowed bypasses the block check — existing accepted convos are not retroactively quarantined")
    func testAllowedBypassesBlock() {
        let repo = MockContactsRepository(
            contacts: [.mock(inboxId: Self.creator, isBlocked: true)]
        )
        let filter = InboundConversationFilter(contactsRepository: repo)

        let allowedDecision = filter.decide(
            consentState: .allowed,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(allowedDecision == .deliver)
    }

    @Test(".denied consent rejects")
    func testDeniedRejects() {
        let repo = MockContactsRepository(contacts: [])
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .denied,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: false
        )
        #expect(decision == .reject)
    }

    @Test("Block check takes precedence over invite-flow handshake (still quarantines)")
    func testBlockedBeatsInviteFlow() {
        let repo = MockContactsRepository(
            contacts: [.mock(inboxId: Self.creator, isBlocked: true)]
        )
        let filter = InboundConversationFilter(contactsRepository: repo)

        let decision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: true
        )
        // Even with an outgoing invite handshake on file, a current block
        // overrides — held in quarantine, recoverable on unblock.
        #expect(decision == .quarantine)
    }
}
