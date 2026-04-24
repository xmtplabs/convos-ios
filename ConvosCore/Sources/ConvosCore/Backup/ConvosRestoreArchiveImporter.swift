import Foundation
@preconcurrency import XMTPiOS

/// Production `RestoreArchiveImporting` implementation using a throwaway
/// `Client.build`.
///
/// `Client.build` joins an existing inbox by id without minting a new
/// installation, provided the XMTP DB at the target path is empty.
/// `RestoreManager` guarantees that precondition by stashing any
/// pre-restore `xmtp-*.db3` family aside before invoking. After
/// `importArchive` completes, `dropLocalDatabaseConnection` explicitly
/// releases the SQLCipher pool — LibXMTP's pool is **not** ARC-managed,
/// so dropping the Swift reference alone would leave the real client
/// unable to reopen the same DB.
public struct ConvosRestoreArchiveImporter: RestoreArchiveImporting {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func importArchive(
        at path: URL,
        encryptionKey: Data,
        identity: KeychainIdentity
    ) async throws -> String {
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let options = ClientOptions(
            api: api,
            dbEncryptionKey: identity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            // Device Sync is explicitly off for the throwaway — its worker
            // would start a sync attempt the moment the client comes up,
            // stepping on the in-flight archive import and confusing the
            // first post-restore sync when the real client boots.
            deviceSyncEnabled: false
        )

        let client = try await Client.build(
            publicIdentity: identity.keys.signingKey.identity,
            options: options,
            inboxId: identity.inboxId
        )
        defer { try? client.dropLocalDatabaseConnection() }

        try await client.importArchive(path: path.path, encryptionKey: encryptionKey)
        return client.installationId
    }
}
