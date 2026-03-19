import Foundation
import GRDB
@preconcurrency import XMTPiOS

public struct VaultHealthIssue: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case memberHasNoKeys
        case unknownDeviceName
        case staleVaultSyncState
    }

    public let kind: Kind
    public let inboxId: String
    public let detail: String
}

public actor VaultHealthCheck {
    private let vaultClient: VaultClient
    private let keyCoordinator: VaultKeyCoordinator
    private let deviceManager: VaultDeviceManager
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseReader: any DatabaseReader
    private let databaseWriter: (any DatabaseWriter)?

    init(
        vaultClient: VaultClient,
        keyCoordinator: VaultKeyCoordinator,
        deviceManager: VaultDeviceManager,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: (any DatabaseWriter)?
    ) {
        self.vaultClient = vaultClient
        self.keyCoordinator = keyCoordinator
        self.deviceManager = deviceManager
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
    }

    public func runCheck() async -> [VaultHealthIssue] {
        guard await vaultClient.isConnected else { return [] }

        var issues: [VaultHealthIssue] = []

        let memberIssues = await checkMembersHaveKeys()
        issues.append(contentsOf: memberIssues)

        let nameIssues = await checkDeviceNames()
        issues.append(contentsOf: nameIssues)

        let staleIssues = await checkStaleSyncState()
        issues.append(contentsOf: staleIssues)

        if !issues.isEmpty {
            Log.warning("VaultHealthCheck: found \(issues.count) issue(s)")
            for issue in issues {
                Log.warning("  \(issue.kind): \(issue.detail)")
            }
        }

        return issues
    }

    public func runCheckAndRepair() async -> [VaultHealthIssue] {
        let issues = await runCheck()

        for issue in issues {
            switch issue.kind {
            case .memberHasNoKeys:
                await repairMissingKeys()
            case .unknownDeviceName:
                await repairDeviceNames()
            case .staleVaultSyncState:
                await repairStaleSyncState(inboxId: issue.inboxId)
            }
        }

        return issues
    }

    // MARK: - Checks

    private func checkMembersHaveKeys() async -> [VaultHealthIssue] {
        guard let selfInboxId = await vaultClient.inboxId else { return [] }

        guard let members = try? await vaultClient.members() else { return [] }
        let otherMembers = members.filter { $0.inboxId != selfInboxId }
        guard !otherMembers.isEmpty else { return [] }

        var bundledInboxIds: Set<String> = []
        if let messages = try? await vaultClient.vaultGroupMessages() {
            for message in messages {
                if let bundle: DeviceKeyBundleContent = try? message.content() {
                    for key in bundle.keys {
                        bundledInboxIds.insert(key.inboxId)
                    }
                } else if let share: DeviceKeyShareContent = try? message.content() {
                    bundledInboxIds.insert(share.inboxId)
                }
            }
        }

        let localInboxIds: Set<String> = (try? await databaseReader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT inboxId FROM inbox WHERE isVault = 0")
            return Set(rows.map { $0["inboxId"] as String })
        }) ?? []

        guard !localInboxIds.isEmpty, bundledInboxIds.isEmpty else { return [] }

        return [VaultHealthIssue(
            kind: .memberHasNoKeys,
            inboxId: selfInboxId,
            detail: "This device is a vault member with \(localInboxIds.count) local inbox(es) but no key bundles found in vault group"
        )]
    }

    private func checkDeviceNames() async -> [VaultHealthIssue] {
        var issues: [VaultHealthIssue] = []
        do {
            let devices = try VaultDeviceRepository(dbReader: databaseReader).fetchAll()
            for device in devices where device.name == "Unknown device" {
                issues.append(VaultHealthIssue(
                    kind: .unknownDeviceName,
                    inboxId: device.inboxId,
                    detail: "Device \(device.inboxId) has unknown name"
                ))
            }
        } catch {
            Log.error("VaultHealthCheck: failed to fetch devices: \(error)")
        }
        return issues
    }

    private func checkStaleSyncState() async -> [VaultHealthIssue] {
        var issues: [VaultHealthIssue] = []
        do {
            let staleInboxIds: [String] = try await databaseReader.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT inboxId FROM inbox
                    WHERE vaultSyncState = ?
                    AND vaultSyncAttempts >= 3
                    """, arguments: [VaultSyncState.failed.rawValue])
                return rows.map { $0["inboxId"] as String }
            }
            for inboxId in staleInboxIds {
                issues.append(VaultHealthIssue(
                    kind: .staleVaultSyncState,
                    inboxId: inboxId,
                    detail: "Inbox \(inboxId) failed sync after max attempts"
                ))
            }
        } catch {
            Log.error("VaultHealthCheck: failed to check stale sync state: \(error)")
        }
        return issues
    }

    // MARK: - Repairs

    private func repairMissingKeys() async {
        Log.info("VaultHealthCheck: requesting key re-share from vault group")
        await keyCoordinator.checkUnsharedInboxes()
    }

    private func repairDeviceNames() async {
        Log.info("VaultHealthCheck: re-syncing device names")
        await deviceManager.syncToDatabase()
    }

    private func repairStaleSyncState(inboxId: String) async {
        guard let databaseWriter else { return }
        Log.info("VaultHealthCheck: resetting stale sync state for inbox \(inboxId)")
        try? await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE inbox SET vaultSyncState = ?, vaultSyncAttempts = 0 WHERE inboxId = ?",
                arguments: [VaultSyncState.pending.rawValue, inboxId]
            )
        }
    }
}
