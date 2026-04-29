import ConvosCore
import SwiftUI

/// Debug surface for QA / engineering. Shows live backup/restore
/// diagnostics — schema generation, last-success timestamp, flag
/// state, pending archive-import failure, available restore bundle —
/// plus a debug "simulate background run" button so QA can exercise
/// the scheduler without waiting on iOS.
///
/// Reachable only from Debug builds via `DebugExportView`.
struct BackupDebugView: View {
    let environment: AppEnvironment
    var backupCoordinator: BackupCoordinator?

    @State private var isSimulating: Bool = false
    @State private var snapshot: Snapshot = .init()

    struct Snapshot {
        var schemaGeneration: String = LegacyDataWipe.currentGeneration
        var lastBackupAt: Date?
        var flagSet: Bool = false
        var transaction: RestoreTransaction?
        var pendingFailure: PendingArchiveImportFailure?
        var availableBackup: AvailableBackup?
        var availableBackupCount: Int = 0
        var iCloudContainerIdentifier: String?
        var iCloudContainerReachable: Bool = false
        var iCloudAccountStatus: String = "unknown"
        var keychainIdentityPresent: Bool = false
        var keychainInboxId: String?
        var keychainClientId: String?
        var databaseKeyFingerprint: String?
    }

    var body: some View {
        List {
            Section("Configuration") {
                row("Schema generation", value: snapshot.schemaGeneration)
                row("iCloud container", value: snapshot.iCloudContainerIdentifier ?? "(none)")
                row(
                    "iCloud reachable",
                    value: snapshot.iCloudContainerReachable
                        ? "yes"
                        : (snapshot.iCloudContainerIdentifier == nil
                            ? "no (identifier missing)"
                            : "no (container not provisioned or user signed out)")
                )
                row("iCloud account status", value: snapshot.iCloudAccountStatus)
            }

            Section("Keychain identity (synced)") {
                row("Identity present", value: snapshot.keychainIdentityPresent ? "yes" : "no")
                if let inboxId = snapshot.keychainInboxId {
                    row("inboxId", value: inboxId)
                }
                if let clientId = snapshot.keychainClientId {
                    row("clientId", value: clientId)
                }
                if let fingerprint = snapshot.databaseKeyFingerprint {
                    row("databaseKey fingerprint", value: fingerprint)
                }
            }

            Section("Last backup") {
                row("Last success", value: snapshot.lastBackupAt.map { $0.formatted() } ?? "never")
                row("Backup in progress", value: BackupScheduler.shared.isBackupInProgress ? "yes" : "no")
            }

            Section("Restore state") {
                row("RestoreInProgressFlag", value: snapshot.flagSet ? "set" : "clear")
                if let transaction = snapshot.transaction {
                    row("Transaction", value: "\(transaction.phase.rawValue) (\(transaction.id.uuidString.prefix(8)))")
                }
                if let failure = snapshot.pendingFailure {
                    row("Partial-restore reason", value: failure.reason)
                }
            }

            Section("Available restores") {
                row("Backups visible", value: "\(snapshot.availableBackupCount)")
                if let available = snapshot.availableBackup {
                    row("Newest from", value: available.sidecar.deviceName)
                    row("Created", value: available.sidecar.createdAt.formatted())
                    row("Conversations", value: "\(available.sidecar.conversationCount)")
                }
            }

            Section("Debug actions") {
                let refresh: @MainActor () -> Void = {
                    Task { await self.refresh() }
                }
                Button(action: refresh) {
                    HStack {
                        Text("Refresh")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                let simulate: @MainActor () -> Void = {
                    isSimulating = true
                    Task {
                        await BackupScheduler.shared.simulateBackgroundRunForDebug()
                        isSimulating = false
                        await self.refresh()
                    }
                }
                Button {
                    simulate()
                } label: {
                    HStack {
                        Text("Run background backup now")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        if isSimulating {
                            ProgressView()
                        } else {
                            Image(systemName: "ladybug")
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                }
                .disabled(isSimulating)
                .accessibilityIdentifier("simulate-background-backup-button")
            }
        }
        .navigationTitle("Backup debug")
        .task { await refresh() }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.colorTextPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(.colorTextSecondary)
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func refresh() async {
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        var snapshot = Snapshot()
        snapshot.schemaGeneration = LegacyDataWipe.currentGeneration
        snapshot.iCloudContainerIdentifier = environment.iCloudContainerIdentifier
        if let containerId = environment.iCloudContainerIdentifier {
            snapshot.iCloudContainerReachable = FileManager.default
                .url(forUbiquityContainerIdentifier: containerId) != nil
        }
        snapshot.iCloudAccountStatus = Self.iCloudAccountStatusDescription()
        snapshot.lastBackupAt = defaults.object(forKey: "convos.backup.lastSuccessfulAt") as? Date
        snapshot.flagSet = RestoreInProgressFlag.isSet(environment: environment)
        snapshot.transaction = RestoreTransactionStore.load(environment: environment)
        snapshot.pendingFailure = PendingArchiveImportFailureStorage.load(environment: environment)
        if let coordinator = backupCoordinator {
            await coordinator.viewModel.refresh()
            snapshot.availableBackup = coordinator.viewModel.availableRestore
            snapshot.availableBackupCount = coordinator.viewModel.availableRestores.count
            if let identity = try? coordinator.identityStoreSnapshot() {
                snapshot.keychainIdentityPresent = true
                snapshot.keychainInboxId = identity.inboxId
                snapshot.keychainClientId = identity.clientId
                snapshot.databaseKeyFingerprint = Self.fingerprint(identity.keys.databaseKey)
            }
        }
        self.snapshot = snapshot
    }

    /// Reads `FileManager.default.ubiquityIdentityToken`, which is the
    /// non-CloudKit signal for "is the user signed into iCloud Drive on
    /// this device". CloudKit's `CKContainer.accountStatus` would be
    /// more granular but requires the `com.apple.developer.icloud-services`
    /// entitlement — Convos doesn't ship that, so calling it crashes.
    private static func iCloudAccountStatusDescription() -> String {
        if FileManager.default.ubiquityIdentityToken != nil {
            return "signed in (iCloud Drive token present)"
        }
        return "no iCloud Drive token (signed out, restricted, or unavailable)"
    }

    /// Short fingerprint of the database key — first 8 raw bytes formatted
    /// as hex. Lets QA verify across devices that the same identity key
    /// is in use without exposing the full secret in the UI.
    private static func fingerprint(_ data: Data) -> String {
        data.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
