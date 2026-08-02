import Combine
@testable import ConvosCore
import ConvosMetrics
import Foundation
import os
import Testing

/// Subject-driven contacts stub so tests can emit repository changes on demand.
private final class StubContactsRepository: ContactsRepositoryProtocol, @unchecked Sendable {
    let subject: CurrentValueSubject<[Contact], Never>

    init(contacts: [Contact]) {
        self.subject = CurrentValueSubject(contacts)
    }

    var contactsPublisher: AnyPublisher<[Contact], Never> {
        subject.eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Contact] {
        subject.value
    }

    func isContact(inboxId: String) throws -> Bool {
        subject.value.contains { $0.inboxId == inboxId }
    }

    func isBlocked(inboxId: String) throws -> Bool {
        false
    }

    func fetchContact(inboxId: String) throws -> Contact? {
        subject.value.first { $0.inboxId == inboxId }
    }

    func fetchContacts(templateIds: [String]) throws -> [Contact] {
        []
    }

    func sourceConversations(forIds ids: Set<String>) throws -> [String: ContactSourceConversation] {
        [:]
    }
}

/// Subject-driven conversations stub so tests can emit repository changes on demand.
private final class StubConversationsRepository: ConversationsRepositoryProtocol, @unchecked Sendable {
    let subject: CurrentValueSubject<[Conversation], Never>

    init(conversations: [Conversation]) {
        self.subject = CurrentValueSubject(conversations)
    }

    var conversationsPublisher: AnyPublisher<[Conversation], Never> {
        subject.eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Conversation] {
        subject.value
    }

    func fetchAll() async throws -> [Conversation] {
        subject.value
    }

    func findOneToOne(with inboxId: String, excluding excludedConversationId: String?) throws -> Conversation? {
        nil
    }

    func conversationsPublisher(withAgentTemplateId templateId: String) -> AnyPublisher<AgentTemplateConversations, Never> {
        Just(AgentTemplateConversations(addedByCurrentUser: [], addedByOthers: [])).eraseToAnyPublisher()
    }
}

/// Thread-safe sink target for collected emissions.
private final class Collector: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[UserProperties]> = .init(initialState: [])

    var values: [UserProperties] {
        lock.withLock { $0 }
    }

    func append(_ value: UserProperties) {
        lock.withLock { $0.append(value) }
    }
}

private func makeContacts(count: Int) -> [Contact] {
    (0..<count).map { index in
        Contact(
            inboxId: "inbox-\(index)",
            displayName: "Contact \(index)",
            avatarURL: nil,
            addedAt: Date(),
            addedViaConversationId: nil
        )
    }
}

/// The builder's publisher throttles upstream database churn and drops
/// captures whose analytics-visible content did not change, so the
/// analytics SDK does not receive a network capture per database write.
struct UserPropertiesBuilderTests {
    /// Returns true as soon as `condition` holds, or false at `timeout`.
    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("First emission passes through and reflects repository content")
    func firstEmissionContent() async {
        let contactsRepository = StubContactsRepository(contacts: makeContacts(count: 3))
        let conversationsRepository = StubConversationsRepository(conversations: [.mock(id: "convo-1"), .mock(id: "convo-2")])
        let builder = UserPropertiesBuilder(
            contactsRepository: contactsRepository,
            conversationsRepository: conversationsRepository,
            accountId: "account-123",
            throttleInterval: 0.05,
            throttleQueue: DispatchQueue(label: "test.userprops")
        )
        let collector = Collector()
        let cancellable = builder.publisher().sink { collector.append($0) }
        defer { cancellable.cancel() }

        let received = await waitUntil(.seconds(5)) { !collector.values.isEmpty }
        #expect(received)
        #expect(collector.values.first?.contactCount == 3)
        #expect(collector.values.first?.conversationCount == 2)
        #expect(collector.values.first?.accountId == "account-123")
    }

    @Test("A burst of upstream changes collapses to a handful of emissions")
    func throttleCollapsesBursts() async {
        let contactsRepository = StubContactsRepository(contacts: makeContacts(count: 1))
        let conversationsRepository = StubConversationsRepository(conversations: [])
        let builder = UserPropertiesBuilder(
            contactsRepository: contactsRepository,
            conversationsRepository: conversationsRepository,
            accountId: nil,
            throttleInterval: 0.2,
            throttleQueue: DispatchQueue(label: "test.userprops")
        )
        let collector = Collector()
        let cancellable = builder.publisher().sink { collector.append($0) }
        defer { cancellable.cancel() }

        let receivedFirst = await waitUntil(.seconds(5)) { !collector.values.isEmpty }
        #expect(receivedFirst)

        let burstSize = 10
        for count in 2...(burstSize + 1) {
            contactsRepository.subject.send(makeContacts(count: count))
        }

        // latest: true guarantees the final upstream value eventually lands.
        let receivedLatest = await waitUntil(.seconds(5)) {
            collector.values.last?.contactCount == burstSize + 1
        }
        #expect(receivedLatest)
        #expect(collector.values.count < burstSize, "a rapid burst should not produce one emission per upstream change")
    }

    @Test("Recomputes where only the wall-clock-derived age changed are deduplicated")
    func dedupeDropsAgeOnlyRecomputes() async throws {
        let contacts = makeContacts(count: 2)
        let contactsRepository = StubContactsRepository(contacts: contacts)
        // A non-empty conversation list makes maxActiveConvoAge nonzero and
        // strictly increasing across recomputes, which is exactly what the
        // dedupe must ignore.
        let conversationsRepository = StubConversationsRepository(conversations: [.mock(id: "convo-1")])
        let builder = UserPropertiesBuilder(
            contactsRepository: contactsRepository,
            conversationsRepository: conversationsRepository,
            accountId: nil,
            throttleInterval: 0.05,
            throttleQueue: DispatchQueue(label: "test.userprops")
        )
        let collector = Collector()
        let cancellable = builder.publisher().sink { collector.append($0) }
        defer { cancellable.cancel() }

        let receivedFirst = await waitUntil(.seconds(5)) { !collector.values.isEmpty }
        #expect(receivedFirst)

        // Each resend lands in its own throttle window, forcing a recompute
        // whose only difference is the age field.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(100))
            contactsRepository.subject.send(contacts)
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(collector.values.count == 1, "identical recomputes should be deduplicated")
    }
}
