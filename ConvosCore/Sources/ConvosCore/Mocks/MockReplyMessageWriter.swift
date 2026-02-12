import Foundation

public actor MockReplyMessageWriter: ReplyMessageWriterProtocol {
    public struct ReplyRecord: Equatable, Sendable {
        public let text: String
        public let parentMessageId: String
        public let conversationId: String
    }

    public var replies: [ReplyRecord] = []

    public init() {}

    public func sendReply(text: String, to parentMessageId: String, in conversationId: String) async throws {
        replies.append(.init(text: text, parentMessageId: parentMessageId, conversationId: conversationId))
    }
}
