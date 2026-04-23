import Foundation

/// Imports a single-inbox XMTP archive during restore. The real
/// implementation constructs a throwaway `Client.build` against a fresh
/// empty XMTP DB so the running session isn't racing a second client on
/// the same SQLCipher pool. Tests inject a deterministic stub.
public protocol RestoreArchiveImporting: Sendable {
    /// Imports `path` (sealed with `encryptionKey`) into the XMTP DB for
    /// the given restored identity. Callers must have staged any existing
    /// xmtp-*.db3 files aside before invoking — the importer opens a
    /// client against an empty DB to avoid mixing in stale state.
    func importArchive(
        at path: URL,
        encryptionKey: Data,
        identity: KeychainIdentity
    ) async throws
}
