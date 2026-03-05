import Foundation
@preconcurrency import XMTPiOS

public protocol VaultSessionIntegration: Sendable {
    func startVault(signingKey: SigningKey, options: ClientOptions) async throws
    func stopVault()
    func pauseVault()
    func resumeVault() async
    func notifyConversationCreated(_ keyInfo: ConversationKeyInfo)
}

extension VaultManager: VaultSessionIntegration {
    public func startVault(signingKey: SigningKey, options: ClientOptions) async throws {
        try await connect(signingKey: signingKey, options: options)
    }

    public func stopVault() {
        disconnect()
    }

    public func pauseVault() {
        pause()
    }

    public func resumeVault() async {
        await resume()
    }

    public func notifyConversationCreated(_ keyInfo: ConversationKeyInfo) {
        conversationKeyCreated(keyInfo)
    }
}
