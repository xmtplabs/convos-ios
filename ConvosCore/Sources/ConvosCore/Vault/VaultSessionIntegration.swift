import Foundation
@preconcurrency import XMTPiOS

extension VaultManager: VaultServiceProtocol {
    public func startVault(signingKey: SigningKey, options: ClientOptions) async throws {
        try await connect(signingKey: signingKey, options: options)
    }

    public func stopVault() async {
        await disconnect()
    }

    public func pauseVault() async {
        await pause()
    }

    public func resumeVault() async {
        await resume()
    }
}
