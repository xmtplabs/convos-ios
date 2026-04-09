import ConvosCore
import SwiftUI

struct DebugExportView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol
    var databaseManager: (any DatabaseManagerProtocol)?

    var body: some View {
        List {
            DebugViewSection(environment: environment, session: session, databaseManager: databaseManager)
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
