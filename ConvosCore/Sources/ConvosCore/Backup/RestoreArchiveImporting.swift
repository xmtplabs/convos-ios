import Foundation

public struct RestoreArchiveImportResult: Sendable, Equatable {
    public let installationId: String
    public let archiveImportFailureReason: String?

    public init(installationId: String, archiveImportFailureReason: String? = nil) {
        self.installationId = installationId
        self.archiveImportFailureReason = archiveImportFailureReason
    }

    public var didImportArchive: Bool {
        archiveImportFailureReason == nil
    }
}

/// Imports a single-inbox XMTP archive during restore. The real
/// implementation constructs a throwaway `Client.create` against a fresh
/// empty XMTP DB so the running session isn't racing a second client on
/// the same SQLCipher pool. Tests inject a deterministic stub.
public protocol RestoreArchiveImporting: Sendable {
    /// Registers a new installation for the restored identity, then imports
    /// `path` (sealed with `encryptionKey`) into that installation's XMTP DB.
    /// Callers must have staged any existing xmtp-*.db3 files aside before
    /// invoking — the importer opens a client against an empty DB to avoid
    /// mixing in stale state.
    ///
    /// Throws only if no new installation could be created. Once an
    /// installation exists, archive-import failure is returned in
    /// `archiveImportFailureReason` so the restore can still keep this
    /// installation and revoke the old devices.
    func importArchive(
        at path: URL,
        encryptionKey: Data,
        identity: KeychainIdentity
    ) async throws -> RestoreArchiveImportResult
}
