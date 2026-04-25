import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// Shared helpers used by the `XMTPiOSAdapter` conversation / group / dm
/// wrappers. Lives alongside them so the value-mapper file stays a pure
/// projection layer.

// MARK: - Send options helpers

/// Translates the abstraction-level `MessagingSendOptions` onto the
/// XMTPiOS parameter objects. Kept as a small helper so each adapter
/// method is a one-liner and the `contentType: nil` semantics stay
/// consistent between group and DM code.
enum XMTPiOSSendOptionsMapper {
    static func xmtpSendOptions(_ options: MessagingSendOptions?) -> XMTPiOS.SendOptions? {
        guard let options else { return nil }
        return XMTPiOS.SendOptions(
            compression: options.compression?.xmtpCompression,
            contentType: options.contentType.xmtpContentTypeID
        )
    }

    static func xmtpVisibilityOptions(
        _ options: MessagingSendOptions?
    ) -> XMTPiOS.MessageVisibilityOptions {
        XMTPiOS.MessageVisibilityOptions(shouldPush: options?.shouldPush ?? true)
    }
}

// MARK: - Exclude content type mapping

/// The abstraction's message-query exclude-list is typed as
/// `[MessagingContentType]` (Convos-owned). XMTPiOS's query takes
/// `[StandardContentType]` (a constrained enum of XIP-spec standard
/// types). Map each Convos content type onto the XMTPiOS enum where
/// a match exists, drop custom types (they aren't part of the libxmtp
/// filter enum).
enum XMTPiOSContentTypeMapper {
    static func standardContentType(
        for contentType: MessagingContentType
    ) -> XMTPiOS.StandardContentType? {
        switch contentType {
        case .text: return .text
        case .reply: return .reply
        case .reaction, .reactionV2: return .reaction
        case .attachment: return .attachment
        case .remoteAttachment: return .remoteAttachment
        case .multiRemoteAttachment: return .multiRemoteAttachment
        case .groupUpdated: return .groupUpdated
        case .readReceipt: return .readReceipt
        default: return nil
        }
    }
}

// MARK: - Message stream bridging

/// Bridges an `AsyncThrowingStream<DecodedMessage, Error>` coming out of
/// XMTPiOS into a `MessagingStream<MessagingMessage>` by mapping each
/// element through `MessagingMessage.init(_ xmtpDecodedMessage:)`.
///
/// Uses `@unchecked Sendable` pipe isolation: the source stream's
/// `DecodedMessage` elements hold a non-Sendable `FfiMessage` payload,
/// so we cannot simply pass the source stream into a detached Task.
/// Instead we hold the source in a bounded box that only the single
/// forwarding Task touches. Matches the ad-hoc `_MessagingDecodedPayloadBox`
/// pattern from `Storage/XMTP DB Representations/MessagingMessage+XMTPiOS.swift`.
enum XMTPiOSMessageStreamBridge {
    static func bridge(
        _ xmtpStream: AsyncThrowingStream<XMTPiOS.DecodedMessage, Error>
    ) -> MessagingStream<MessagingMessage> {
        let source = _XMTPStreamBox(stream: xmtpStream)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await xmtpMessage in source.stream {
                        if let mapped = try? MessagingMessage(xmtpMessage) {
                            continuation.yield(mapped)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// `@unchecked Sendable` around `AsyncThrowingStream<DecodedMessage, Error>`.
/// The stream is iterator-owned once we hand it to the forwarding
/// Task; no cross-task sharing of state happens.
private struct _XMTPStreamBox: @unchecked Sendable {
    let stream: AsyncThrowingStream<XMTPiOS.DecodedMessage, Error>
}

// MARK: - Conversation stream bridging

/// Same as `XMTPiOSMessageStreamBridge` but for conversation streams.
enum XMTPiOSConversationStreamBridge {
    static func bridge(
        _ xmtpStream: AsyncThrowingStream<XMTPiOS.Conversation, Error>
    ) -> MessagingStream<MessagingConversation> {
        let source = _XMTPConversationStreamBox(stream: xmtpStream)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await xmtpConversation in source.stream {
                        continuation.yield(
                            XMTPiOSConversationAdapter.messagingConversation(xmtpConversation)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private struct _XMTPConversationStreamBox: @unchecked Sendable {
    let stream: AsyncThrowingStream<XMTPiOS.Conversation, Error>
}
