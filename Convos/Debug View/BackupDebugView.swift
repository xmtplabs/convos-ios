import ConvosCore
import SwiftUI

struct BackupDebugView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol

    @State private var isPerformingAction: Bool = false
    @State private var actionResultMessage: String?
    @State private var showingActionResult: Bool = false
    @State private var lastBackupMetadata: BackupBundleMetadata?
    @State private var isLoading: Bool = true
    @State private var backupDirectoryPath: String?

    var body: some View {
        List {
            statusSection
            actionsSection
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
                    value: backupDirectoryPath != nil ? "Available" : "Unavailable"
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
        } header: {
            Text("Actions")
        } footer: {
            Text("Creates an encrypted backup bundle containing the vault archive, conversation archives, and database.")
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isPerformingAction {
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

    private func createBackupAction() {
        runAction(title: "Create backup") {
            let backupManager = try makeBackupManager()
            let outputURL = try await backupManager.createBackup()
            await refreshStatus()
            return "Backup created at:\n\(outputURL.lastPathComponent)"
        }
    }

    private func runAction(title: String, operation: @escaping @Sendable () async throws -> String) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

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
            }
        }
    }

    private func refreshStatus() async {
        await MainActor.run { isLoading = true }

        let backupDir = resolveBackupDirectory()
        let metadata: BackupBundleMetadata? = if let backupDir {
            try? BackupBundleMetadata.read(from: backupDir)
        } else {
            nil
        }

        await MainActor.run {
            backupDirectoryPath = backupDir?.path
            lastBackupMetadata = metadata
            isLoading = false
        }
    }

    private func resolveBackupDirectory() -> URL? {
        let deviceId = DeviceInfo.deviceIdentifier
        let containerId = environment.iCloudContainerIdentifier

        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId) {
            let dir = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)
            guard BackupBundleMetadata.exists(in: dir) else { return nil }
            return dir
        }

        return nil
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

        var errorDescription: String? {
            switch self {
            case .vaultUnavailable:
                return "Vault service is not available"
            }
        }
    }
}
