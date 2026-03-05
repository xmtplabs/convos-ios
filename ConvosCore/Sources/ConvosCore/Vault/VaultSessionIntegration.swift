import Foundation
@preconcurrency import XMTPiOS

extension VaultManager: VaultServiceProtocol {
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

    public func shareNewKey(_ keyInfo: InboxKeyInfo) async {
        guard isConnected, hasMultipleDevices else { return }

        let entry = VaultIdentityEntry(
            conversationId: "",
            inboxId: keyInfo.inboxId,
            clientId: keyInfo.clientId,
            privateKeyData: keyInfo.privateKeyData,
            databaseKey: keyInfo.databaseKey
        )

        do {
            try await shareKey(entry)
        } catch {
            delegate?.vaultManager(self, didEncounterError: error)
        }
    }
}
