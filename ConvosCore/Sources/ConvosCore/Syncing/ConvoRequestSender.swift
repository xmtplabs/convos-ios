import ConvosProfiles
import Foundation
@preconcurrency import XMTPiOS

public protocol ConvoRequestSenderProtocol: Sendable {
    func sendDMRequest(
        to recipientInboxId: String,
        originConversationId: String,
        senderProfileSnapshot: ProfileSnapshot?,
        client: AnyClientProvider
    ) async throws -> String
}

public final class ConvoRequestSender: ConvoRequestSenderProtocol, @unchecked Sendable {
    public init() {}

    public func sendDMRequest(
        to recipientInboxId: String,
        originConversationId: String,
        senderProfileSnapshot: ProfileSnapshot?,
        client: AnyClientProvider
    ) async throws -> String {
        let convoTag = UUID().uuidString
        let newInboxId = client.inboxId

        var request = ConvoRequest()
        request.newInboxID = newInboxId
        request.convoTag = convoTag
        request.originConversationID = originConversationId
        if let senderProfileSnapshot {
            request.senderProfileSnapshot = senderProfileSnapshot
        }

        let dm = try await client.newConversation(with: recipientInboxId)
        let encoded = try ConvoRequestCodec().encode(content: request)
        try await dm.sendEncodedContent(encoded)

        Log.info("Sent convo request to \(recipientInboxId.prefix(8)) via back channel (tag: \(convoTag.prefix(8)))")
        return convoTag
    }
}
