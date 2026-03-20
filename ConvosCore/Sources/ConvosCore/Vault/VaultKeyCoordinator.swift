import Combine
import Foundation
import GRDB
@preconcurrency import XMTPiOS

struct InboxConversationRow {
    let inboxId: String
    let clientId: String
    let conversationId: String
}

actor VaultKeyCoordinator {
    private let vaultClient: VaultClient
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseReader: any DatabaseReader
    private var databaseWriter: (any DatabaseWriter)?
    private let deviceName: String
    private var inboxObservationCancellable: AnyCancellable?
    private var inboxesBeingShared: Set<String> = []

    private weak var eventHandler: (any VaultEventHandler)?

    func setEventHandler(_ handler: any VaultEventHandler) {
        self.eventHandler = handler
    }

    init(
        vaultClient: VaultClient,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        deviceName: String
    ) {
        self.vaultClient = vaultClient
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.deviceName = deviceName
    }

    func setDatabaseWriter(_ writer: any DatabaseWriter) {
        self.databaseWriter = writer
    }

    // MARK: - Observation

    func startObservingInboxes() {
        let observation = ValueObservation.tracking { db in
            try Self.fetchUnsharedRows(db)
        }

        inboxObservationCancellable = observation
            .publisher(in: databaseReader)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] unsharedRows in
                    guard let self, !unsharedRows.isEmpty else { return }
                    Task { await self.shareUnsharedInboxes(unsharedRows) }
                }
            )
        Log.info("Vault: started observing inboxes for key sharing")
    }

    func stopObserving() {
        inboxObservationCancellable?.cancel()
        inboxObservationCancellable = nil
    }

    // MARK: - Key Sharing

    func shareUnsharedInboxes(_ rows: [InboxConversationRow]) async {
        guard await vaultClient.isConnected, hasMultipleDevices, let databaseWriter else { return }

        let newRows = rows.filter { !inboxesBeingShared.contains($0.inboxId) }
        guard !newRows.isEmpty else { return }

        for row in newRows {
            inboxesBeingShared.insert(row.inboxId)
        }

        Log.info("Vault: found \(newRows.count) unshared inbox(es) with conversations")

        for row in newRows {
            await shareKeyForInbox(row.inboxId, clientId: row.clientId)

            try? await databaseWriter.write { db in
                try db.execute(
                    sql: "UPDATE inbox SET sharedToVault = 1 WHERE inboxId = ?",
                    arguments: [row.inboxId]
                )
            }
            inboxesBeingShared.remove(row.inboxId)
        }
    }

    func shareAllKeys(pendingPeerDeviceNames: [String: String]) async throws {
        guard let installationId = await vaultClient.installationId else {
            throw VaultClientError.notConnected
        }

        let inboxRows = try await databaseReader.read { db -> [InboxConversationRow] in
            let sql = """
                SELECT i.inboxId, i.clientId, c.id as conversationId
                FROM inbox i
                INNER JOIN conversation c ON c.clientId = i.clientId
                    AND c.id NOT LIKE 'draft-%'
                    AND c.isUnused = 0
                WHERE i.isVault = 0
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                InboxConversationRow(
                    inboxId: row["inboxId"],
                    clientId: row["clientId"],
                    conversationId: row["conversationId"] ?? ""
                )
            }
        }

        var keys: [DeviceKeyEntry] = []
        for item in inboxRows {
            guard let identity = try? await identityStore.identity(for: item.inboxId) else { continue }
            keys.append(DeviceKeyEntry(
                conversationId: item.conversationId,
                inboxId: item.inboxId,
                clientId: item.clientId,
                privateKeyData: Data(identity.keys.privateKey.secp256K1.bytes),
                databaseKey: identity.keys.databaseKey
            ))
        }

        let peerNames = pendingPeerDeviceNames.isEmpty ? nil : pendingPeerDeviceNames
        let bundle = DeviceKeyBundleContent(
            keys: keys,
            senderInstallationId: installationId,
            senderDeviceName: deviceName,
            peerDeviceNames: peerNames
        )

        try await vaultClient.send(bundle, codec: DeviceKeyBundleCodec())
        if let databaseWriter, !inboxRows.isEmpty {
            let inboxIds = inboxRows.map { $0.inboxId }
            try? await databaseWriter.write { db in
                for id in inboxIds {
                    try db.execute(
                        sql: "UPDATE inbox SET sharedToVault = 1 WHERE inboxId = ?",
                        arguments: [id]
                    )
                }
            }
        }
    }

    func checkUnsharedInboxes() async {
        guard await vaultClient.isConnected, hasMultipleDevices else { return }
        guard let rows = try? await databaseReader.read({ db in
            try Self.fetchUnsharedRows(db)
        }), !rows.isEmpty else { return }
        await shareUnsharedInboxes(rows)
    }

    // MARK: - Key Import

    func importKeyShare(_ share: DeviceKeyShareContent) async {
        guard await !hasIdentity(for: share.inboxId) else { return }

        do {
            let keys = try KeychainIdentityKeys(
                privateKeyData: share.privateKeyData,
                databaseKey: share.databaseKey
            )
            let identity = try await identityStore.save(
                inboxId: share.inboxId,
                clientId: share.clientId,
                keys: keys
            )

            if let databaseWriter {
                let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                try await inboxWriter.save(inboxId: identity.inboxId, clientId: identity.clientId)
            }

            await eventHandler?.vaultDidImportInbox(inboxId: identity.inboxId, clientId: identity.clientId)
        } catch {
            Log.error("Vault: failed to import key share for \(share.inboxId): \(error)")
        }
    }

    func importKeyBundle(_ bundle: DeviceKeyBundleContent) async {
        var importedEntries: [(inboxId: String, clientId: String)] = []
        for key in bundle.keys {
            guard await !hasIdentity(for: key.inboxId) else { continue }

            do {
                let keys = try KeychainIdentityKeys(
                    privateKeyData: key.privateKeyData,
                    databaseKey: key.databaseKey
                )
                let identity = try await identityStore.save(
                    inboxId: key.inboxId,
                    clientId: key.clientId,
                    keys: keys
                )

                if let databaseWriter {
                    let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                    try await inboxWriter.save(inboxId: identity.inboxId, clientId: identity.clientId)
                }

                importedEntries.append((inboxId: identity.inboxId, clientId: identity.clientId))
            } catch {
                Log.error("Vault: failed to import key bundle entry for \(key.inboxId): \(error)")
            }
        }

        if !importedEntries.isEmpty {
            let importedInboxIds = Set(importedEntries.map { $0.inboxId })
            Log.info("Vault: imported \(importedEntries.count) key(s) from bundle")
            await eventHandler?.vaultDidImportKeyBundle(inboxIds: importedInboxIds, count: importedEntries.count)
        }

        if !bundle.keys.isEmpty {
            NotificationCenter.default.post(name: .vaultDidReceiveKeyBundle, object: nil)
        }
    }

    // MARK: - Private

    private func shareKeyForInbox(_ inboxId: String, clientId: String) async {
        guard let identity = try? await identityStore.identity(for: inboxId) else {
            Log.warning("Vault: no keychain identity for inbox \(inboxId)")
            return
        }

        let conversationId = try? await databaseReader.read { db -> String? in
            let sql = """
                SELECT c.id FROM conversation c
                WHERE c.clientId = ? AND c.id NOT LIKE 'draft-%'
                LIMIT 1
                """
            return try String.fetchOne(db, sql: sql, arguments: [clientId])
        }

        let keyInfo = InboxKeyInfo(
            inboxId: inboxId,
            clientId: clientId,
            conversationId: conversationId ?? "",
            privateKeyData: Data(identity.keys.privateKey.secp256K1.bytes),
            databaseKey: identity.keys.databaseKey
        )
        Log.info("Vault: sharing key for inbox \(inboxId)")
        await sendKeyShare(keyInfo)
    }

    private func sendKeyShare(_ keyInfo: InboxKeyInfo) async {
        guard await vaultClient.isConnected, hasMultipleDevices, let installationId = await vaultClient.installationId else { return }
        let share = DeviceKeyShareContent(
            conversationId: keyInfo.conversationId,
            inboxId: keyInfo.inboxId,
            clientId: keyInfo.clientId,
            privateKeyData: keyInfo.privateKeyData,
            databaseKey: keyInfo.databaseKey,
            senderInstallationId: installationId,
            senderDeviceName: deviceName
        )

        do {
            try await vaultClient.send(share, codec: DeviceKeyShareCodec())
        } catch {
            Log.error("Vault: failed to share key for \(keyInfo.inboxId): \(error)")
        }
    }

    private func hasIdentity(for inboxId: String) async -> Bool {
        (try? await identityStore.identity(for: inboxId)) != nil
    }

    private var hasMultipleDevices: Bool {
        let count = (try? VaultDeviceRepository(dbReader: databaseReader).count()) ?? 0
        return count > 1
    }

    static func fetchUnsharedRows(_ db: Database) throws -> [InboxConversationRow] {
        let sql = """
            SELECT i.inboxId, i.clientId, c.id as conversationId
            FROM inbox i
            INNER JOIN conversation c ON c.clientId = i.clientId
                AND c.id NOT LIKE 'draft-%'
                AND c.isUnused = 0
            WHERE i.isVault = 0 AND i.sharedToVault = 0
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            InboxConversationRow(
                inboxId: row["inboxId"],
                clientId: row["clientId"],
                conversationId: row["conversationId"] ?? ""
            )
        }
    }
}
