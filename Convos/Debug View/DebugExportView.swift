import ConvosCore
import ConvosMetrics
import SwiftUI

struct DebugExportView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions

    var body: some View {
        List {
            DebugViewSection(environment: environment, session: session, coreActions: coreActions)
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Debug")
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { DebugExportView(environment: .tests, session: MockInboxesService(), coreActions: NoOpCoreActions()) }
}
