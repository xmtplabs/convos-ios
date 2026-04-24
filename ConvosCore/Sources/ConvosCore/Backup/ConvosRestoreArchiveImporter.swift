import Foundation
@preconcurrency import XMTPiOS

/// Production `RestoreArchiveImporting` implementation. Registers a
/// throwaway installation via `Client.create` on the fresh, empty
/// XMTP DB that `RestoreManager` stashed aside any pre-restore state
/// for, then imports the archive into it.
///
/// Why `Client.create` and not `Client.build`:
/// - `Client.build` requires an already-initialized local MLS DB (it
///   won't mint a new installation) and throws
///   `ClientError.creationError("No signing key found, …")` when
///   called with a fresh empty DB.
/// - The restore flow explicitly *wants* a fresh installation — the
///   whole point of the post-import revocation is that this new
///   installation becomes the only surviving one. So `Client.create`
///   with the identity's signing key is correct: it registers a new
///   installation on the existing inbox and gives us an id we can
///   hand to `XMTPInstallationRevoker` as the keeper.
///
/// After `importArchive` completes, `dropLocalDatabaseConnection`
/// explicitly releases the SQLCipher pool — LibXMTP's pool is *not*
/// ARC-managed, so dropping the Swift reference alone would leave the
/// real client unable to reopen the same DB when `SessionManager
/// .resumeAfterRestore` kicks it back up.
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

        let client = try await Client.create(
            account: identity.keys.signingKey,
            options: options
        )
        defer { try? client.dropLocalDatabaseConnection() }

        try await client.importArchive(path: path.path, encryptionKey: encryptionKey)

        // After archive import, the XMTP SDK's consent state for
        // restored groups may be `unknown`. StreamProcessor's
        // `shouldProcessConversation` silently drops messages from
        // groups that aren't `allowed`, so the first incoming message
        // after restore would never reach GRDB and the UI would stay
        // empty. Explicitly set consent to `allowed` on every group
        // in the imported archive so the first post-restore stream
        // message flows through.
        let groups = try client.conversations.listGroups()
        for group in groups {
            try? await group.updateConsentState(state: .allowed)
        }
        if !groups.isEmpty {
            Log.info("ConvosRestoreArchiveImporter: set consent=allowed for \(groups.count) group(s)")
        }

        return client.installationId
    }
}
