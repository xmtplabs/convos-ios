import ConvosCore
import Security
import SwiftUI

struct VaultKeySyncDebugView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol

    @State private var snapshot: Snapshot = .empty
    @State private var isLoading: Bool = true
    @State private var isPerformingAction: Bool = false
    @State private var actionResultMessage: String?
    @State private var showingActionResult: Bool = false
    @State private var pendingDestructiveAction: DestructiveAction?

    var body: some View {
        List {
            statusSection
            keysDetailSection
            backupFilesSection
            actionsSection
        }
        .navigationTitle("Vault Key Sync")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
        .alert("Vault Key Sync", isPresented: $showingActionResult, presenting: actionResultMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            pendingDestructiveAction?.title ?? "",
            isPresented: destructiveActionBinding,
            titleVisibility: .visible
        ) {
            if let pendingDestructiveAction {
                Button(pendingDestructiveAction.confirmButtonTitle, role: .destructive) {
                    runDestructiveAction(pendingDestructiveAction)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveAction = nil
            }
        } message: {
            Text(pendingDestructiveAction?.message ?? "")
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
                statusRow(title: "iCloud account available", value: snapshot.isICloudAccountAvailable ? "Yes" : "No")
                statusRow(title: "Vault bootstrap", value: snapshot.bootstrapState)
                statusRow(title: "Vault inbox ID", value: snapshot.vaultInboxId ?? "Unavailable", monospaced: true)
                statusRow(title: "Local vault keys", value: "\(snapshot.localVaultKeyCount)")
                statusRow(title: "iCloud vault keys", value: "\(snapshot.iCloudVaultKeyCount)")
                statusRow(title: "Has iCloud-only keys", value: snapshot.hasICloudOnlyKeys ? "Yes" : "No")

                if let bootstrapErrorMessage = snapshot.bootstrapErrorMessage {
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                        Text("Vault bootstrap error")
                        Text(bootstrapErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }

                statusRow(
                    title: "Last refreshed",
                    value: snapshot.lastRefreshed.formatted(date: .omitted, time: .standard)
                )
            }
        }
    }

    @ViewBuilder
    private var keysDetailSection: some View {
        if !isLoading {
            Section("Vault Keys") {
                if snapshot.vaultKeys.isEmpty {
                    Text("No vault keys found")
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    ForEach(snapshot.vaultKeys) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if key.inboxId == snapshot.vaultInboxId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                                Text(key.inboxId)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 8) {
                                Text("client: \(key.clientId)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.colorTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 8) {
                                Label(
                                    key.isLocal ? "Local" : "No local",
                                    systemImage: key.isLocal ? "checkmark.circle" : "xmark.circle"
                                )
                                .foregroundStyle(key.isLocal ? .green : .red)
                                Label(
                                    key.isICloud ? "iCloud" : "No iCloud",
                                    systemImage: key.isICloud ? "checkmark.circle" : "xmark.circle"
                                )
                                .foregroundStyle(key.isICloud ? .green : .red)
                            }
                            .font(.caption2)
                            HStack(spacing: 12) {
                                if key.isLocal {
                                    let deleteLocalAction = { deleteLocalKey(inboxId: key.inboxId) }
                                    Button("Delete local", role: .destructive, action: deleteLocalAction)
                                        .font(.caption)
                                }
                                if key.isICloud {
                                    let deleteICloudAction = { deleteICloudKey(inboxId: key.inboxId) }
                                    Button("Delete iCloud", role: .destructive, action: deleteICloudAction)
                                        .font(.caption)
                                }
                                if key.isICloud && !key.isLocal {
                                    let adoptAction = { adoptICloudKey(inboxId: key.inboxId) }
                                    Button("Adopt locally", action: adoptAction)
                                        .font(.caption)
                                }
                            }
                            .disabled(isPerformingAction)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var backupFilesSection: some View {
        if !isLoading {
            Section("iCloud Backup Files") {
                if snapshot.backupFiles.isEmpty {
                    Text("No backups found in iCloud container")
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    ForEach(snapshot.backupFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.deviceName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            HStack(spacing: 12) {
                                Label(file.metadataCreatedAt, systemImage: "clock")
                                Label(file.size, systemImage: "doc")
                            }
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            HStack(spacing: 12) {
                                Label("\(file.inboxCount) inbox(es)", systemImage: "person.2")
                                Text(file.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.caption2)
                            .foregroundStyle(.colorTextTertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button(action: refreshStatusAction) {
                actionLabel("Refresh status")
            }
            .accessibilityIdentifier("vault-key-sync-refresh-button")
            .disabled(isPerformingAction)

            Button(action: syncLocalToICloudAction) {
                actionLabel("Sync local → iCloud now")
            }
            .accessibilityIdentifier("vault-key-sync-sync-button")
            .disabled(isPerformingAction)

            Button(role: .destructive, action: promptDeleteLocalKeysAction) {
                actionLabel("Simulate restore (delete local vault keys only)")
            }
            .accessibilityIdentifier("vault-key-sync-delete-local-button")
            .disabled(isPerformingAction)

            Button(action: recoverLocalFromICloudAction) {
                actionLabel("Recover local from iCloud now")
            }
            .accessibilityIdentifier("vault-key-sync-recover-local-button")
            .disabled(isPerformingAction)

            Button(role: .destructive, action: promptDeleteICloudKeysAction) {
                actionLabel("Delete iCloud vault copy only")
            }
            .accessibilityIdentifier("vault-key-sync-delete-icloud-button")
            .disabled(isPerformingAction)

            Button(action: resyncICloudKeysAction) {
                actionLabel("Re-sync iCloud copies")
            }
            .accessibilityIdentifier("vault-key-sync-resync-button")
            .disabled(isPerformingAction)
        } header: {
            Text("Actions")
        } footer: {
            Text("Use simulate restore to verify iCloud fallback without resetting your Apple ID or device.")
        }
    }

    private var destructiveActionBinding: Binding<Bool> {
        Binding(
            get: { pendingDestructiveAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDestructiveAction = nil
                }
            }
        )
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
    private func statusRow(title: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func deleteLocalKey(inboxId: String) {
        let store = makeLocalVaultStore()
        runAction(title: "Delete local key") {
            try await store.delete(inboxId: inboxId)
            await refreshStatus()
            return "Deleted local key: \(inboxId)"
        }
    }

    private func deleteICloudKey(inboxId: String) {
        let store = makeICloudVaultStore()
        runAction(title: "Delete iCloud key") {
            try await store.delete(inboxId: inboxId)
            await refreshStatus()
            return "Deleted iCloud key: \(inboxId)"
        }
    }

    private func adoptICloudKey(inboxId: String) {
        let dualStore = ICloudIdentityStore(localStore: makeLocalVaultStore(), icloudStore: makeICloudVaultStore())
        runAction(title: "Adopt iCloud key") {
            _ = try await dualStore.identity(for: inboxId)
            await refreshStatus()
            return "Adopted iCloud key locally: \(inboxId)"
        }
    }

    private func refreshStatusAction() {
        runAction(title: "Refresh status") {
            await refreshStatus()
            return "Refreshed vault key sync status."
        }
    }

    private func syncLocalToICloudAction() {
        runAction(title: "Sync local → iCloud") {
            await syncLocalToICloud()
            return "Triggered local vault key sync to iCloud."
        }
    }

    private func promptDeleteLocalKeysAction() {
        pendingDestructiveAction = .deleteLocalKeys
    }

    private func recoverLocalFromICloudAction() {
        runAction(title: "Recover local from iCloud") {
            try await recoverLocalFromICloud()
        }
    }

    private func promptDeleteICloudKeysAction() {
        pendingDestructiveAction = .deleteICloudKeys
    }

    private func resyncICloudKeysAction() {
        runAction(title: "Re-sync iCloud copies") {
            await syncLocalToICloud()
            return "Triggered re-sync of local vault keys to iCloud."
        }
    }

    private func runDestructiveAction(_ action: DestructiveAction) {
        pendingDestructiveAction = nil

        switch action {
        case .deleteLocalKeys:
            runAction(title: "Delete local vault keys") {
                try await deleteLocalVaultKeys()
            }

        case .deleteICloudKeys:
            runAction(title: "Delete iCloud vault keys") {
                try await deleteICloudVaultKeys()
            }
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
        await MainActor.run {
            isLoading = true
        }

        let updatedSnapshot = await loadSnapshot()

        await MainActor.run {
            snapshot = updatedSnapshot
            isLoading = false
        }
    }

    private func loadSnapshot() async -> Snapshot {
        let localStore = makeLocalVaultStore()
        let iCloudStore = makeICloudVaultStore()
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)

        let localIdentities = (try? await localStore.loadAll()) ?? []
        let iCloudIdentities = (try? await iCloudStore.loadAll()) ?? []
        let hasICloudOnlyKeys = await dualStore.hasICloudOnlyKeys()

        let bootstrapInfo = await loadVaultBootstrapInfo()

        let localInboxIds = Set(localIdentities.map(\.inboxId))
        let iCloudInboxIds = Set(iCloudIdentities.map(\.inboxId))
        let allInboxIds = localInboxIds.union(iCloudInboxIds)

        let vaultKeys: [VaultKeyInfo] = allInboxIds.sorted().map { inboxId in
            let identity = localIdentities.first(where: { $0.inboxId == inboxId })
                ?? iCloudIdentities.first(where: { $0.inboxId == inboxId })
            return VaultKeyInfo(
                inboxId: inboxId,
                clientId: identity?.clientId ?? "unknown",
                isLocal: localInboxIds.contains(inboxId),
                isICloud: iCloudInboxIds.contains(inboxId)
            )
        }

        let backupFiles = loadBackupFiles()

        return Snapshot(
            isICloudAccountAvailable: ICloudIdentityStore.isICloudAccountAvailable,
            bootstrapState: bootstrapInfo.state,
            bootstrapErrorMessage: bootstrapInfo.errorMessage,
            vaultInboxId: bootstrapInfo.vaultInboxId,
            localVaultKeyCount: localIdentities.count,
            iCloudVaultKeyCount: iCloudIdentities.count,
            hasICloudOnlyKeys: hasICloudOnlyKeys,
            lastRefreshed: Date(),
            vaultKeys: vaultKeys,
            backupFiles: backupFiles
        )
    }

    private func loadBackupFiles() -> [BackupFileInfo] {
        let containerId = environment.iCloudContainerIdentifier
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId) else {
            return []
        }
        let backupsDir = containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)

        guard let deviceDirs = try? FileManager.default.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return deviceDirs.compactMap { deviceDir in
            guard let metadata = try? BackupBundleMetadata.read(from: deviceDir) else { return nil }
            let bundlePath = deviceDir.appendingPathComponent("backup-latest.encrypted")
            let size = (try? FileManager.default.attributesOfItem(atPath: bundlePath.path)[.size] as? Int) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return BackupFileInfo(
                deviceName: metadata.deviceName,
                path: deviceDir.lastPathComponent,
                size: sizeStr,
                metadataCreatedAt: metadata.createdAt.formatted(date: .abbreviated, time: .shortened),
                inboxCount: metadata.inboxCount
            )
        }
    }

    private func loadVaultBootstrapInfo() async -> VaultBootstrapInfo {
        guard let vaultManager = session.vaultService as? VaultManager else {
            return .init(state: "Unavailable", errorMessage: nil, vaultInboxId: nil)
        }

        let state = await vaultManager.bootstrapState
        let vaultInboxId = await vaultManager.vaultInboxId

        switch state {
        case .notStarted:
            return .init(state: "Not started", errorMessage: nil, vaultInboxId: vaultInboxId)
        case .ready:
            return .init(state: "Ready", errorMessage: nil, vaultInboxId: vaultInboxId)
        case let .failed(message):
            return .init(state: "Failed", errorMessage: message, vaultInboxId: vaultInboxId)
        }
    }

    private func syncLocalToICloud() async {
        let dualStore = ICloudIdentityStore(localStore: makeLocalVaultStore(), icloudStore: makeICloudVaultStore())
        await dualStore.syncLocalKeysToICloud()
        await refreshStatus()
    }

    private func deleteLocalVaultKeys() async throws -> String {
        let localStore = makeLocalVaultStore()
        try await localStore.deleteAll()
        await refreshStatus()
        return "Deleted local vault key copies. Reopen the app to validate iCloud fallback."
    }

    private func deleteICloudVaultKeys() async throws -> String {
        let dualStore = ICloudIdentityStore(localStore: makeLocalVaultStore(), icloudStore: makeICloudVaultStore())
        try await dualStore.deleteAllICloudCopies()
        await refreshStatus()
        return "Deleted iCloud vault key copies. Local vault keys were preserved."
    }

    private func recoverLocalFromICloud() async throws -> String {
        let dualStore = ICloudIdentityStore(localStore: makeLocalVaultStore(), icloudStore: makeICloudVaultStore())

        if let vaultInboxId = snapshot.vaultInboxId {
            _ = try await dualStore.identity(for: vaultInboxId)
            await refreshStatus()
            return "Recovered local vault key for inbox \(vaultInboxId)."
        }

        let iCloudStore = makeICloudVaultStore()
        let iCloudIdentities = try await iCloudStore.loadAll()

        guard let firstICloudIdentity = iCloudIdentities.first else {
            throw VaultKeySyncDebugError.noICloudKeysAvailable
        }

        _ = try await dualStore.identity(for: firstICloudIdentity.inboxId)
        await refreshStatus()
        return "Recovered local vault key for inbox \(firstICloudIdentity.inboxId)."
    }

    private func makeLocalVaultStore() -> KeychainIdentityStore {
        KeychainIdentityStore(
            accessGroup: environment.keychainAccessGroup,
            service: Constant.vaultIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    private func makeICloudVaultStore() -> KeychainIdentityStore {
        KeychainIdentityStore(
            accessGroup: environment.keychainAccessGroup,
            service: Constant.vaultICloudIdentityService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
    }
}

private extension VaultKeySyncDebugView {
    struct VaultKeyInfo: Identifiable {
        let inboxId: String
        let clientId: String
        let isLocal: Bool
        let isICloud: Bool
        var id: String { inboxId }
    }

    struct BackupFileInfo: Identifiable {
        let deviceName: String
        let path: String
        let size: String
        let metadataCreatedAt: String
        let inboxCount: Int
        var id: String { path }
    }

    struct Snapshot {
        let isICloudAccountAvailable: Bool
        let bootstrapState: String
        let bootstrapErrorMessage: String?
        let vaultInboxId: String?
        let localVaultKeyCount: Int
        let iCloudVaultKeyCount: Int
        let hasICloudOnlyKeys: Bool
        let lastRefreshed: Date
        let vaultKeys: [VaultKeyInfo]
        let backupFiles: [BackupFileInfo]

        static let empty: Snapshot = Snapshot(
            isICloudAccountAvailable: false,
            bootstrapState: "Unavailable",
            bootstrapErrorMessage: nil,
            vaultInboxId: nil,
            localVaultKeyCount: 0,
            iCloudVaultKeyCount: 0,
            hasICloudOnlyKeys: false,
            lastRefreshed: .distantPast,
            vaultKeys: [],
            backupFiles: []
        )
    }

    struct VaultBootstrapInfo {
        let state: String
        let errorMessage: String?
        let vaultInboxId: String?
    }

    enum DestructiveAction {
        case deleteLocalKeys
        case deleteICloudKeys

        var title: String {
            switch self {
            case .deleteLocalKeys:
                return "Delete local vault keys?"
            case .deleteICloudKeys:
                return "Delete iCloud vault keys?"
            }
        }

        var message: String {
            switch self {
            case .deleteLocalKeys:
                return "This removes only local vault key copies. iCloud copies stay intact."
            case .deleteICloudKeys:
                return "This removes only iCloud vault key copies. Local copies stay intact."
            }
        }

        var confirmButtonTitle: String {
            switch self {
            case .deleteLocalKeys:
                return "Delete Local Copies"
            case .deleteICloudKeys:
                return "Delete iCloud Copies"
            }
        }
    }

    enum VaultKeySyncDebugError: LocalizedError {
        case noICloudKeysAvailable

        var errorDescription: String? {
            switch self {
            case .noICloudKeysAvailable:
                return "No vault keys exist in iCloud Keychain."
            }
        }
    }

    enum Constant {
        static let vaultIdentityService: String = "org.convos.vault-identity"
        static let vaultICloudIdentityService: String = "org.convos.vault-identity.icloud"
    }
}

#Preview {
    NavigationStack {
        VaultKeySyncDebugView(environment: .tests, session: MockInboxesService())
    }
}
