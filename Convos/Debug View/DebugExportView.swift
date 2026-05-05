import ConvosCore
import SwiftUI

struct DebugExportView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol
    var backupCoordinator: BackupCoordinator?

    var body: some View {
        List {
            DebugViewSection(environment: environment, session: session)
            Section("Backup") {
                NavigationLink {
                    BackupDebugView(
                        environment: environment,
                        backupCoordinator: backupCoordinator
                    )
                } label: {
                    Text("Backup diagnostics")
                }
                .accessibilityIdentifier("backup-debug-row")
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Debug")
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { DebugExportView(environment: .tests, session: MockInboxesService()) }
}
