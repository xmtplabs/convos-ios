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

    @Test("Blocked contact rejects, even when consent is .allowed")
    func testBlockedRejectsRegardlessOfConsent() {
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
        let unknownDecision = filter.decide(
            consentState: .unknown,
            creatorInboxId: Self.creator,
            clientInboxId: Self.me,
            hasOutgoingJoinRequest: true
        )
        #expect(allowedDecision == .reject)
        #expect(unknownDecision == .reject)
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

    @Test("Block check takes precedence over invite-flow handshake")
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
        #expect(decision == .reject)
    }
}
