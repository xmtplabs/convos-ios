import ConvosCore
import SwiftUI

@Observable
@MainActor
final class BackupRestoreViewModel {
    var lastBackupDate: Date?
    var lastBackupDeviceName: String?
    var availableRestoreMetadata: BackupBundleMetadata?
    var availableRestoreURL: URL?
    var iCloudAvailable: Bool = false
    var isBackingUp: Bool = false
    var isRestoring: Bool = false
    var restoreState: RestoreState = .idle
    var alertMessage: String?
    var showingAlert: Bool = false
    var showingRestoreConfirmation: Bool = false
    var isLoading: Bool = true

    private let session: any SessionManagerProtocol
    private let databaseManager: (any DatabaseManagerProtocol)?
    private let environment: AppEnvironment
    private let onRestoreComplete: (() -> Void)?

    init(
        session: any SessionManagerProtocol,
        databaseManager: (any DatabaseManagerProtocol)?,
        environment: AppEnvironment,
        onRestoreComplete: (() -> Void)? = nil
    ) {
        self.session = session
        self.databaseManager = databaseManager
        self.environment = environment
        self.onRestoreComplete = onRestoreComplete
    }

    func refresh() async {
        isLoading = true
        let cloudAvailable = FileManager.default.url(
            forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier
        ) != nil

        let ownBackupDir = resolveOwnBackupDirectory()
        let ownMetadata: BackupBundleMetadata? = if let ownBackupDir {
            try? BackupBundleMetadata.read(from: ownBackupDir)
        } else {
            nil
        }

        let available = RestoreManager.findAvailableBackup(environment: environment)

        iCloudAvailable = cloudAvailable
        lastBackupDate = ownMetadata?.createdAt
        lastBackupDeviceName = ownMetadata?.deviceName
        if let available {
            availableRestoreURL = available.url
            availableRestoreMetadata = available.metadata
        }
        isLoading = false
    }

    func createBackup() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }

        do {
            let manager = try makeBackupManager()
            _ = try await manager.createBackup()
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    func confirmRestore() {
        showingRestoreConfirmation = true
    }

    func restore() async {
        guard let bundleURL = availableRestoreURL, !isRestoring else { return }
        isRestoring = true

        do {
            let manager = try makeRestoreManager()
            try await manager.restoreFromBackup(bundleURL: bundleURL)
            restoreState = await manager.state
            isRestoring = false
            onRestoreComplete?()
        } catch {
            isRestoring = false
            restoreState = .failed(error.localizedDescription)
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    var restoreProgressText: String? {
        switch restoreState {
        case .idle: return nil
        case .decrypting: return "Decrypting backup…"
        case .importingVault: return "Importing vault…"
        case let .savingKeys(completed, total): return "Restoring keys (\(completed)/\(total))…"
        case .replacingDatabase: return "Replacing database…"
        case let .importingConversations(completed, total): return "Importing conversations (\(completed)/\(total))…"
        case let .completed(inboxCount, _): return "Restored \(inboxCount) conversation\(inboxCount == 1 ? "" : "s")"
        case let .failed(message): return "Failed: \(message)"
        }
    }

    private func resolveOwnBackupDirectory() -> URL? {
        let deviceId = DeviceInfo.deviceIdentifier
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier) {
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

    private func makeBackupManager() throws -> BackupManager {
        guard let vaultManager = session.vaultService as? VaultManager else {
            throw BackupRestoreError.vaultUnavailable
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

    private func makeRestoreManager() throws -> RestoreManager {
        guard let databaseManager else {
            throw BackupRestoreError.databaseUnavailable
        }
        let accessGroup = environment.keychainAccessGroup
        let identityStore = KeychainIdentityStore(accessGroup: accessGroup)
        let vaultKeyStore = makeVaultKeyStore()
        let archiveImporter = ConvosRestoreArchiveImporter(
            identityStore: identityStore,
            environment: environment
        )
        let vaultManager = session.vaultService as? VaultManager
        let capturedEnvironment = environment
        let revoker: RestoreInstallationRevoker = { inboxId, signingKey, keepId in
            try await XMTPInstallationRevoker.revokeOtherInstallations(
                inboxId: inboxId,
                signingKey: signingKey,
                keepInstallationId: keepId,
                environment: capturedEnvironment
            )
        }
        return RestoreManager(
            vaultKeyStore: vaultKeyStore,
            identityStore: identityStore,
            databaseManager: databaseManager,
            archiveImporter: archiveImporter,
            restoreLifecycleController: session as? any RestoreLifecycleControlling,
            vaultManager: vaultManager,
            installationRevoker: revoker,
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
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)
        return VaultKeyStore(store: dualStore)
    }

    private enum BackupRestoreError: LocalizedError {
        case vaultUnavailable
        case databaseUnavailable

        var errorDescription: String? {
            switch self {
            case .vaultUnavailable:
                return "Vault is not available. Try again in a moment."
            case .databaseUnavailable:
                return "Database is not available."
            }
        }
    }
}

private struct RestoreConfirmationModifier: ViewModifier {
    @Bindable var viewModel: BackupRestoreViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Restore from backup?",
            isPresented: $viewModel.showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                Task { await viewModel.restore() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let metadata = viewModel.availableRestoreMetadata {
                Text("This will replace your current data with the backup from \(metadata.deviceName) (\(metadata.createdAt.formatted(date: .abbreviated, time: .shortened))).")
            }
        }
    }
}

struct BackupRestoreSettingsView: View {
    @State private var viewModel: BackupRestoreViewModel

    init(
        session: any SessionManagerProtocol,
        databaseManager: (any DatabaseManagerProtocol)?,
        environment: AppEnvironment,
        onRestoreComplete: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: BackupRestoreViewModel(
            session: session,
            databaseManager: databaseManager,
            environment: environment,
            onRestoreComplete: onRestoreComplete
        ))
    }

    var body: some View {
        List {
            backupSection

            if viewModel.availableRestoreMetadata != nil {
                restoreSection
            }

            statusSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Backup & Restore")
        .task { await viewModel.refresh() }
        .alert("Error", isPresented: $viewModel.showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = viewModel.alertMessage {
                Text(message)
            }
        }
        .modifier(RestoreConfirmationModifier(viewModel: viewModel))
    }

    private func startBackup() {
        Task { await viewModel.createBackup() }
    }

    private func startRestore() {
        Task { await viewModel.restore() }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            if viewModel.isBackingUp {
                HStack {
                    Text("Backing up…")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    ProgressView()
                }
            } else {
                Button(action: startBackup) {
                    HStack {
                        Text("Back up now")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            if let date = viewModel.lastBackupDate {
                Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("No backup yet")
            }
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        Section {
            if viewModel.isRestoring {
                HStack {
                    Text(viewModel.restoreProgressText ?? "Restoring…")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    ProgressView()
                }
            } else if case .completed = viewModel.restoreState {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(viewModel.restoreProgressText ?? "Restore complete")
                        .foregroundStyle(.colorTextPrimary)
                }
            } else {
                let action = { viewModel.confirmRestore() }
                Button(action: action) {
                    HStack {
                        Text("Restore from backup")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
        } header: {
            Text("Restore")
        } footer: {
            if let metadata = viewModel.availableRestoreMetadata {
                Text("From \(metadata.deviceName) · \(metadata.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(metadata.inboxCount) conversation\(metadata.inboxCount == 1 ? "" : "s")")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Text("iCloud")
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                if viewModel.iCloudAvailable {
                    Label("Available", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                } else {
                    Label("Unavailable", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
    }
}
