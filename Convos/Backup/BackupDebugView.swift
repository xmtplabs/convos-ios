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
        var iCloudContainerIdentifier: String?
        var iCloudContainerReachable: Bool = false
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

            if let available = snapshot.availableBackup {
                Section("Available restore") {
                    row("From", value: available.sidecar.deviceName)
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
        snapshot.lastBackupAt = defaults.object(forKey: "convos.backup.lastSuccessfulAt") as? Date
        snapshot.flagSet = RestoreInProgressFlag.isSet(environment: environment)
        snapshot.transaction = RestoreTransactionStore.load(environment: environment)
        snapshot.pendingFailure = PendingArchiveImportFailureStorage.load(environment: environment)
        if let coordinator = backupCoordinator {
            await coordinator.viewModel.refresh()
            snapshot.availableBackup = coordinator.viewModel.availableRestore
        }
        self.snapshot = snapshot
    }
}
