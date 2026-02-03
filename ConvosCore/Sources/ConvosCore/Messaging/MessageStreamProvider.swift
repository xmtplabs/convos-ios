import Foundation
@preconcurrency import XMTPiOS

public struct StreamedMessage: Sendable {
    public let id: String
    public let conversationId: String
    public let senderInboxId: String
    public let sentAt: Date
    public let content: StreamedMessageContent

    public enum StreamedMessageContent: Sendable {
        case text(String)
        case emoji(String)
        case reaction(emoji: String, targetMessageId: String, action: ReactionAction)
        case attachment(url: String)
        case attachments(urls: [String])
        case groupUpdate
        case unsupported

        public enum ReactionAction: Sendable {
            case added, removed
        }
    }
}

public protocol MessageStreamProviderProtocol: Sendable {
    func stream(
        consentStates: [ConsentState]?
    ) -> AsyncThrowingStream<StreamedMessage, Error>
}

public final class MessageStreamProvider: MessageStreamProviderProtocol, @unchecked Sendable {
    private let inboxStateManager: any InboxStateManagerProtocol

    public init(inboxStateManager: any InboxStateManagerProtocol) {
        self.inboxStateManager = inboxStateManager
    }

    public func stream(
        consentStates: [ConsentState]? = [.allowed, .unknown]
    ) -> AsyncThrowingStream<StreamedMessage, Error> {
        let manager = inboxStateManager
        let states = consentStates
        return AsyncThrowingStream { continuation in
            let streamTask = Task { @Sendable in
                do {
                    let result = try await manager.waitForInboxReadyResult()
                    for try await message in result.client.conversationsProvider.streamAllMessages(
                        type: .all,
                        consentStates: states,
                        onClose: { continuation.finish() }
                    ) {
                        guard !Task.isCancelled else { break }
                        if let streamed = MessageStreamProvider.convert(message) {
                            continuation.yield(streamed)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }

    private static func convert(_ message: DecodedMessage) -> StreamedMessage? {
        let content: StreamedMessage.StreamedMessageContent

        do {
            let encodedContentType = try message.encodedContent.type
            let decodedContent = try message.content() as Any

            switch encodedContentType {
            case ContentTypeText:
                guard let text = decodedContent as? String else { return nil }
                if text.allCharactersEmoji {
                    content = .emoji(text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    content = .text(text)
                }

            case ContentTypeReaction, ContentTypeReactionV2:
                guard let reaction = decodedContent as? Reaction else { return nil }
                let action: StreamedMessage.StreamedMessageContent.ReactionAction =
                    reaction.action == ReactionAction.added ? .added : .removed
                content = .reaction(
                    emoji: reaction.emoji,
                    targetMessageId: reaction.reference,
                    action: action
                )

            case ContentTypeRemoteAttachment:
                guard let attachment = decodedContent as? RemoteAttachment else { return nil }
                content = .attachment(url: attachment.url)

            case ContentTypeMultiRemoteAttachment:
                guard let attachments = decodedContent as? [RemoteAttachment] else { return nil }
                content = .attachments(urls: attachments.map { $0.url })

            case ContentTypeGroupUpdated, ContentTypeExplodeSettings:
                content = .groupUpdate

            default:
                content = .unsupported
            }
        } catch {
            return nil
        }

        return StreamedMessage(
            id: message.id,
            conversationId: message.conversationId,
            senderInboxId: message.senderInboxId,
            sentAt: message.sentAt,
            content: content
        )
    }
}
