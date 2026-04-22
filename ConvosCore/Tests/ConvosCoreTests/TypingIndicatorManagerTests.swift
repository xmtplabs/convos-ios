@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

// MARK: - Codec Tests

@Suite("TypingIndicatorCodec")
struct TypingIndicatorCodecTests {
    @Test("encodes and decodes isTyping true")
    func roundTripTrue() throws {
        let codec = TypingIndicatorCodec()
        let content = TypingIndicatorContent(isTyping: true)
        let encoded = try codec.encode(content: content)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.isTyping == true)
    }

    @Test("encodes and decodes isTyping false")
    func roundTripFalse() throws {
        let codec = TypingIndicatorCodec()
        let content = TypingIndicatorContent(isTyping: false)
        let encoded = try codec.encode(content: content)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.isTyping == false)
    }

    @Test("throws on empty content")
    func emptyContent() {
        let codec = TypingIndicatorCodec()
        var encoded = EncodedContent()
        encoded.type = ContentTypeTypingIndicator
        encoded.content = Data()
        #expect(throws: TypingIndicatorCodecError.emptyContent) {
            try codec.decode(content: encoded)
        }
    }

    @Test("throws on invalid JSON")
    func invalidJSON() {
        let codec = TypingIndicatorCodec()
        var encoded = EncodedContent()
        encoded.type = ContentTypeTypingIndicator
        encoded.content = Data("not json".utf8)
        #expect(throws: TypingIndicatorCodecError.invalidJSONFormat) {
            try codec.decode(content: encoded)
        }
    }

    @Test("shouldPush returns false")
    func shouldPushFalse() throws {
        let codec = TypingIndicatorCodec()
        let result = try codec.shouldPush(content: TypingIndicatorContent(isTyping: true))
        #expect(result == false)
    }

    @Test("fallback returns nil")
    func fallbackNil() throws {
        let codec = TypingIndicatorCodec()
        let result = try codec.fallback(content: TypingIndicatorContent(isTyping: true))
        #expect(result == nil)
    }

    @Test("content type has correct authority and type")
    func contentTypeIdentity() {
        #expect(ContentTypeTypingIndicator.authorityID == "convos.org")
        #expect(ContentTypeTypingIndicator.typeID == "typing_indicator")
        #expect(ContentTypeTypingIndicator.versionMajor == 1)
        #expect(ContentTypeTypingIndicator.versionMinor == 0)
    }
}

// MARK: - Manager Tests

@Suite("TypingIndicatorManager")
@MainActor
struct TypingIndicatorManagerTests {
    @Test("adds typer to conversation")
    func addTyper() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        let typers = manager.typers(for: "conv1")
        #expect(typers.count == 1)
        #expect(typers[0].inboxId == "user1")
    }

    @Test("removes typer on stop")
    func removeTyperOnStop() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: false)

        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("removes typer on message received")
    func removeTyperOnMessageReceived() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleMessageReceived(conversationId: "conv1", senderInboxId: "user1")

        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("tracks multiple typers independently")
    func multipleTypers() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user2", isTyping: true)

        let typers = manager.typers(for: "conv1")
        #expect(typers.count == 2)

        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: false)
        #expect(manager.typers(for: "conv1").count == 1)
        #expect(manager.typers(for: "conv1")[0].inboxId == "user2")
    }

    @Test("tracks typers across conversations")
    func multipleConversations() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv2", senderInboxId: "user2", isTyping: true)

        #expect(manager.typers(for: "conv1").count == 1)
        #expect(manager.typers(for: "conv2").count == 1)
        #expect(manager.typers(for: "conv3").isEmpty)
    }

    @Test("clears all typers for a conversation")
    func clearAll() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user2", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv2", senderInboxId: "user3", isTyping: true)

        manager.clearAll(for: "conv1")

        #expect(manager.typers(for: "conv1").isEmpty)
        #expect(manager.typers(for: "conv2").count == 1)
    }

    @Test("re-adding typer resets position")
    func reAddTyper() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user2", isTyping: true)

        let firstStartedAt = manager.typers(for: "conv1")[0].startedAt

        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        let typers = manager.typers(for: "conv1")
        #expect(typers.count == 2)
        #expect(typers[0].inboxId == "user2")
        #expect(typers[1].inboxId == "user1")
        #expect(typers[1].startedAt >= firstStartedAt)
    }

    @Test("removing nonexistent typer is a no-op")
    func removeNonexistentTyper() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: false)
        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("message received for nonexistent typer is a no-op")
    func messageReceivedNonexistentTyper() {
        let manager = TypingIndicatorManager()
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleMessageReceived(conversationId: "conv1", senderInboxId: "user2")
        #expect(manager.typers(for: "conv1").count == 1)
    }

    @Test("scheduled expiry uses the configured interval")
    func expiryUsesConfiguredInterval() {
        let scheduler = ManualExpiryScheduler()
        let manager = TypingIndicatorManager(expiryInterval: 7, scheduler: scheduler.scheduler())
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending[0].delay == 7)
        #expect(scheduler.pending[0].cancelled == false)
    }

    @Test("firing the scheduled expiry removes the typer")
    func expiryRemovesTyper() {
        let scheduler = ManualExpiryScheduler()
        let manager = TypingIndicatorManager(expiryInterval: 5, scheduler: scheduler.scheduler())
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        #expect(manager.typers(for: "conv1").count == 1)

        scheduler.fire(at: 0)

        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("re-adding the same typer cancels the prior expiry and schedules a new one")
    func reAddResetsExpiry() {
        let scheduler = ManualExpiryScheduler()
        let manager = TypingIndicatorManager(expiryInterval: 5, scheduler: scheduler.scheduler())
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        #expect(scheduler.pending.count == 2)
        #expect(scheduler.pending[0].cancelled == true, "first expiry must be cancelled by re-add")
        #expect(scheduler.pending[1].cancelled == false, "second expiry is the live one")

        // Firing the cancelled action would still call removeTyper — but
        // the manager must guard against that landing post-cancel. Verify
        // the cancelled action is a no-op against the live typer.
        scheduler.fire(at: 0)
        #expect(manager.typers(for: "conv1").count == 1, "cancelled expiry must not remove the live typer")

        scheduler.fire(at: 1)
        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("clearing all cancels pending expiry actions")
    func clearAllCancelsExpiry() {
        let scheduler = ManualExpiryScheduler()
        let manager = TypingIndicatorManager(expiryInterval: 5, scheduler: scheduler.scheduler())
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user2", isTyping: true)

        manager.clearAll(for: "conv1")

        #expect(scheduler.pending[0].cancelled == true)
        #expect(scheduler.pending[1].cancelled == true)
        #expect(manager.typingMembersByConversation["conv1"] == nil)
    }

    @Test("stop typing cancels the pending expiry action")
    func stopTypingCancelsExpiry() {
        let scheduler = ManualExpiryScheduler()
        let manager = TypingIndicatorManager(expiryInterval: 5, scheduler: scheduler.scheduler())
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: false)

        #expect(scheduler.pending[0].cancelled == true)
        #expect(manager.typingMembersByConversation["conv1"] == nil)
    }

    @Test("returns empty array for unknown conversation")
    func unknownConversation() {
        let manager = TypingIndicatorManager()
        #expect(manager.typers(for: "nonexistent").isEmpty)
    }
}

// MARK: - Manual scheduler

/// Test scheduler that captures expiry actions instead of running them
/// against the wall clock. `fire(at:)` invokes a captured action; cancelled
/// actions are ignored, matching production's `Task.isCancelled` guard.
@MainActor
private final class ManualExpiryScheduler {
    struct Pending {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        var cancelled: Bool = false
    }

    private(set) var pending: [Pending] = []

    func scheduler() -> TypingExpiryScheduler {
        { [weak self] delay, action in
            guard let self else { return {} }
            let index = self.pending.count
            self.pending.append(Pending(delay: delay, action: action))
            return { [weak self] in
                self?.pending[index].cancelled = true
            }
        }
    }

    func fire(at index: Int) {
        guard index < pending.count, !pending[index].cancelled else { return }
        pending[index].action()
    }
}
