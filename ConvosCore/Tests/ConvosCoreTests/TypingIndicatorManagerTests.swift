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

    @Test("expiry removes typer after interval")
    func expiryRemovesTyper() async throws {
        let manager = TypingIndicatorManager(expiryInterval: 0.2)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        #expect(manager.typers(for: "conv1").count == 1)

        try await Task.sleep(for: .seconds(0.4))
        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("re-adding typer resets expiry timer")
    func reAddResetsExpiry() async throws {
        let manager = TypingIndicatorManager(expiryInterval: 0.3)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        try await Task.sleep(for: .seconds(0.2))
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)

        try await Task.sleep(for: .seconds(0.2))
        #expect(manager.typers(for: "conv1").count == 1)

        try await Task.sleep(for: .seconds(0.2))
        #expect(manager.typers(for: "conv1").isEmpty)
    }

    @Test("clearing all cancels expiry tasks")
    func clearAllCancelsExpiry() async throws {
        let manager = TypingIndicatorManager(expiryInterval: 0.2)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.clearAll(for: "conv1")

        try await Task.sleep(for: .seconds(0.4))
        #expect(manager.typers(for: "conv1").isEmpty)
        #expect(manager.typingMembersByConversation["conv1"] == nil)
    }

    @Test("stop typing cancels expiry task")
    func stopTypingCancelsExpiry() async throws {
        let manager = TypingIndicatorManager(expiryInterval: 0.2)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: true)
        manager.handleTypingEvent(conversationId: "conv1", senderInboxId: "user1", isTyping: false)

        try await Task.sleep(for: .seconds(0.4))
        #expect(manager.typingMembersByConversation["conv1"] == nil)
    }

    @Test("returns empty array for unknown conversation")
    func unknownConversation() {
        let manager = TypingIndicatorManager()
        #expect(manager.typers(for: "nonexistent").isEmpty)
    }
}
