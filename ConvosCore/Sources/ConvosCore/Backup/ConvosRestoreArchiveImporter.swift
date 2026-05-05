import Foundation
import GRDB
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
/// .resumeAfterRestore` kicks it back up. The call is routed through
/// `XMTPClientProvider` rather than the concrete `XMTPiOS.Client` so
/// the SDK's deprecation warning ("delicate, reconnect required") does
/// not fire — our use case is the documented exception: the throwaway
/// client is being torn down, and the next reconnect happens implicitly
/// when `SessionManager` builds a fresh `Client` against the same DB.
public struct ConvosRestoreArchiveImporter: RestoreArchiveImporting {
    private let environment: AppEnvironment
    private let databaseReader: any DatabaseReader

    public init(environment: AppEnvironment, databaseReader: any DatabaseReader) {
        self.environment = environment
        self.databaseReader = databaseReader
    }

    public func importArchive(
        at path: URL,
        encryptionKey: Data,
        identity: KeychainIdentity
    ) async throws -> RestoreArchiveImportResult {
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
        let releasable: any XMTPClientProvider = client
        defer { try? releasable.dropLocalDatabaseConnection() }

        let installationId = client.installationId

        do {
            try await client.importArchive(path: path.path, encryptionKey: encryptionKey)
            try await allowRestoredConversationConsent(on: client)
            return RestoreArchiveImportResult(installationId: installationId)
        } catch {
            Log.error("ConvosRestoreArchiveImporter: archive import failed after creating installation \(installationId): \(error)")
            return RestoreArchiveImportResult(
                installationId: installationId,
                archiveImportFailureReason: error.localizedDescription
            )
        }
    }

    private func allowRestoredConversationConsent(on client: Client) async throws {
        // After archive import, the XMTP SDK's consent state for
        // restored groups may be `unknown`. StreamProcessor's
        // `shouldProcessConversation` silently drops messages from
        // groups that aren't `allowed`, so the first incoming message
        // after restore would never reach GRDB and the UI would stay
        // empty. Set consent to `allowed` on every group whose id has
        // a matching DBConversation row in the restored GRDB.
        //
        // The filter matters because XMTP's `createArchive` has no
        // per-group filtering and includes every group in the inbox —
        // including the `UnusedConversationCache` prewarm (an MLS
        // group created just-in-time for the next "New" tap, never
        // sent to). The sender strips those rows from the GRDB
        // snapshot, so groups present in XMTP but absent from GRDB
        // are exactly those orphan prewarms. Leaving them at
        // consent=unknown keeps the stream processor's filter
        // dropping them, so they never surface as empty
        // conversations on the restored device.
        let allowedConversationIds = try await databaseReader.read { db in
            try DBConversation
                .select(DBConversation.Columns.id, as: String.self)
                .fetchSet(db)
        }
        let groups = try client.conversations.listGroups()
        var allowedCount = 0
        var skippedCount = 0
        for group in groups {
            if allowedConversationIds.contains(group.id) {
                try? await group.updateConsentState(state: .allowed)
                allowedCount += 1
            } else {
                skippedCount += 1
            }
        }
        if !groups.isEmpty {
            Log.info(
                "ConvosRestoreArchiveImporter: consent=allowed on \(allowedCount) group(s), "
                + "skipped \(skippedCount) orphan group(s) not present in restored GRDB"
            )
        }
    }
}
