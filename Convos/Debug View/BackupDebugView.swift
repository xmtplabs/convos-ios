import ConvosCore
import SwiftUI

struct BackupDebugView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol
    var databaseManager: (any DatabaseManagerProtocol)?

    @State private var isPerformingAction: Bool = false
    @State private var activeAction: String?
    @State private var actionResultMessage: String?
    @State private var showingActionResult: Bool = false
    @State private var lastBackupMetadata: BackupBundleMetadata?
    @State private var availableBackup: (url: URL, metadata: BackupBundleMetadata)?
    @State private var isLoading: Bool = true
    @State private var backupDirectoryPath: String?
    @State private var iCloudAvailable: Bool = false
    @State private var showingRestoreConfirmation: Bool = false

    var body: some View {
        List {
            statusSection
            if activeAction != "Restore" {
                actionsSection
            }
            restoreSection
        }
        .navigationTitle("Backup")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
        .alert("Backup", isPresented: $showingActionResult, presenting: actionResultMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            let confirmAction = { restoreFromBackupAction() }
            Button("Restore", role: .destructive, action: confirmAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = availableBackup {
                let date = backup.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
                Text("This will replace all current conversations and data with the backup from \(backup.metadata.deviceName) (\(date)).")
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if isLoading {
                HStack {
                    Text("Loading status…")
                    Spacer()
                    ProgressView()
                }
            } else {
                statusRow(
                    title: "iCloud container",
                    value: iCloudAvailable ? "Available" : "Unavailable"
                )

                if let metadata = lastBackupMetadata {
                    statusRow(
                        title: "Last backup",
                        value: metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    statusRow(title: "Device", value: metadata.deviceName)
                    statusRow(title: "Inbox count", value: "\(metadata.inboxCount)")
                    statusRow(title: "Bundle version", value: "\(metadata.version)")
                } else {
                    statusRow(title: "Last backup", value: "None")
                }

                if let path = backupDirectoryPath {
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                        Text("Backup path")
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            let refreshAction = { refreshStatusButtonAction() }
            Button(action: refreshAction) {
                actionLabel("Refresh status")
            }
            .disabled(isPerformingAction)

            let backupAction = { createBackupAction() }
            Button(action: backupAction) {
                actionLabel("Create backup now")
            }
            .accessibilityIdentifier("backup-debug-create-button")
            .disabled(isPerformingAction)

            let revokeAction = { revokeVaultInstallationsAction() }
            Button(role: .destructive, action: revokeAction) {
                actionLabel("Revoke all other vault installations")
            }
            .accessibilityIdentifier("backup-debug-revoke-vault-button")
            .disabled(isPerformingAction)
        } header: {
            Text("Actions")
        } footer: {
            Text("Use 'Revoke' to clear extra vault installations accumulated during testing (max 10 per inboxId).")
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        if !isLoading, databaseManager != nil {
            Section {
                if let backup = availableBackup {
                    statusRow(
                        title: "Available backup",
                        value: backup.metadata.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    statusRow(title: "From device", value: backup.metadata.deviceName)
                    statusRow(title: "Conversations", value: "\(backup.metadata.inboxCount)")

                    let promptAction = { showingRestoreConfirmation = true }
                    Button(role: .destructive, action: promptAction) {
                        actionLabel("Restore from backup")
                    }
                    .accessibilityIdentifier("backup-debug-restore-button")
                    .disabled(isPerformingAction)
                } else {
                    statusRow(title: "Available backup", value: "None found")
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring will stop all sessions, replace the database, and import conversation archives. This is destructive and cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if activeAction == title {
                ProgressView()
                    .scaleEffect(0.85)
            }
        }
        .foregroundStyle(.colorTextPrimary)
    }

    @ViewBuilder
    private func statusRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func refreshStatusButtonAction() {
        runAction(title: "Refresh status") {
            await refreshStatus()
            return "Refreshed backup status."
        }
    }

    private func restoreFromBackupAction() {
        guard let backup = availableBackup else { return }
        let restoreManager: RestoreManager
        do {
            restoreManager = try makeRestoreManager()
        } catch {
            actionResultMessage = "Restore failed: \(error.localizedDescription)"
            showingActionResult = true
            return
        }
        runAction(title: "Restore") {
            try await restoreManager.restoreFromBackup(bundleURL: backup.url)
            let state = await restoreManager.state
            if case .completed(let inboxCount, let failedKeyCount) = state {
                var message = "Restore completed: \(inboxCount) conversation(s) restored."
                if failedKeyCount > 0 {
                    message += "\n\(failedKeyCount) key(s) failed to restore."
                }
                return message
            }
            return "Restore completed."
        }
    }

    private func revokeVaultInstallationsAction() {
        let vaultKeyStore = makeVaultKeyStore()
        let vaultManager = session.vaultService as? VaultManager
        runAction(title: "Revoke vault installations") { [environment] in
            let vaultIdentity = try await vaultKeyStore.loadAny()
            let keepId: String? = await vaultManager?.vaultInstallationId
            let count = try await XMTPInstallationRevoker.revokeOtherInstallations(
                inboxId: vaultIdentity.inboxId,
                signingKey: vaultIdentity.keys.signingKey,
                keepInstallationId: keepId,
                environment: environment
            )
            return "Revoked \(count) vault installation(s)."
        }
    }

    private func createBackupAction() {
        let backupManager: BackupManager
        do {
            backupManager = try makeBackupManager()
        } catch {
            actionResultMessage = "Create backup failed: \(error.localizedDescription)"
            showingActionResult = true
            return
        }
        runAction(title: "Create backup") {
            let outputURL = try await backupManager.createBackup()
            await refreshStatus()
            let timestamp = Date().formatted(date: .abbreviated, time: .shortened)
            return "Backup created successfully.\n\(timestamp)"
        }
    }

    private func runAction(title: String, operation: @escaping @Sendable () async throws -> String) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        activeAction = title

        Task {
            let message: String
            do {
                message = try await operation()
            } catch {
                message = "\(title) failed: \(error.localizedDescription)"
            }

            await MainActor.run {
                actionResultMessage = message
                showingActionResult = true
                isPerformingAction = false
                activeAction = nil
            }
        }
    }

    private func refreshStatus() async {
        await MainActor.run { isLoading = true }

        let cloudAvailable = isICloudAvailable()
        let backupDir = resolveBackupDirectory()
        let metadata: BackupBundleMetadata? = if let backupDir {
            try? BackupBundleMetadata.read(from: backupDir)
        } else {
            nil
        }
        let backup = RestoreManager.findAvailableBackup(environment: environment)

        await MainActor.run {
            iCloudAvailable = cloudAvailable
            backupDirectoryPath = backupDir?.path
            lastBackupMetadata = metadata
            availableBackup = backup
            isLoading = false
        }
    }

    private func isICloudAvailable() -> Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier) != nil
    }

    private func resolveBackupDirectory() -> URL? {
        let deviceId = DeviceInfo.deviceIdentifier
        let containerId = environment.iCloudContainerIdentifier

        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId) {
            let dir = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)
            if BackupBundleMetadata.exists(in: dir) { return dir }
        }

        let localDir = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)
        if BackupBundleMetadata.exists(in: localDir) { return localDir }

        return nil
    }

    private func makeRestoreManager() throws -> RestoreManager {
        guard let databaseManager else {
            throw BackupDebugError.databaseManagerUnavailable
        }

        let accessGroup = environment.keychainAccessGroup
        let identityStore = KeychainIdentityStore(accessGroup: accessGroup)
        let vaultKeyStore = makeVaultKeyStore()
        let archiveImporter = ConvosRestoreArchiveImporter(
            identityStore: identityStore,
            environment: environment
        )

        return RestoreManager(
            vaultKeyStore: vaultKeyStore,
            identityStore: identityStore,
            databaseManager: databaseManager,
            archiveImporter: archiveImporter,
            restoreLifecycleController: session as? any RestoreLifecycleControlling,
            environment: environment
        )
    }

    private func makeBackupManager() throws -> BackupManager {
        guard let vaultManager = session.vaultService as? VaultManager else {
            throw BackupDebugError.vaultUnavailable
        }

        let accessGroup = environment.keychainAccessGroup
        let identityStore = KeychainIdentityStore(accessGroup: accessGroup)
        let vaultKeyStore = makeVaultKeyStore()
        let archiveProvider = ConvosBackupArchiveProvider(
            vaultService: vaultManager,
            identityStore: identityStore,
            environment: environment
        )

        return BackupManager(
            vaultKeyStore: vaultKeyStore,
            archiveProvider: archiveProvider,
            identityStore: identityStore,
            databaseReader: session.databaseReader,
            environment: environment
        )
    }

    private func makeVaultKeyStore() -> VaultKeyStore {
        let accessGroup = environment.keychainAccessGroup
        let localStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: "org.convos.vault-identity",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let iCloudStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: "org.convos.vault-identity.icloud",
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)
        return VaultKeyStore(store: dualStore)
    }

    private enum BackupDebugError: LocalizedError {
        case vaultUnavailable
        case databaseManagerUnavailable

        var errorDescription: String? {
            switch self {
            case .vaultUnavailable:
                return "Vault service is not available"
            case .databaseManagerUnavailable:
                return "Database manager is not available"
            }
        }
    }
}
