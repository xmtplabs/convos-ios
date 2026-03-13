import Foundation
@preconcurrency import XMTPiOS

public protocol VaultMessageProcessorProtocol: Sendable {
    func isVaultConversation(_ conversationId: String) async -> Bool
    func processVaultMessage(_ message: DecodedMessage) async
}
