import Foundation

/// Production `BackupArchiveProviding` implementation. Resolves the live
/// XMTP client on demand (via an injected closure so we can honor actor
/// boundaries) and forwards `createArchive` on it.
public struct ConvosBackupArchiveProvider: BackupArchiveProviding {
    /// Resolves the currently-authorized XMTP client. Returning `nil`
    /// signals "no live client right now" — typically because the session
    /// state machine is not in `.ready`.
    public typealias ClientResolver = @Sendable () async throws -> (any XMTPClientProvider)?

    public enum ProviderError: Error, LocalizedError {
        case clientUnavailable

        public var errorDescription: String? {
            switch self {
            case .clientUnavailable:
                return "XMTP client is not available; cannot create archive."
            }
        }
    }

    private let clientResolver: ClientResolver

    public init(clientResolver: @escaping ClientResolver) {
        self.clientResolver = clientResolver
    }

    public func createArchive(at path: URL, encryptionKey: Data) async throws -> XMTPArchiveStats {
        guard let client = try await clientResolver() else {
            throw ProviderError.clientUnavailable
        }
        try await client.createArchive(atPath: path.path, encryptionKey: encryptionKey)
        // The archive metadata time-range is informational for UI, not
        // security-critical. Skip capturing it here — it's available post-hoc
        // from XMTPiOS.Client.archiveMetadata if we ever need it.
        return XMTPArchiveStats(startNs: nil, endNs: nil)
    }
}
