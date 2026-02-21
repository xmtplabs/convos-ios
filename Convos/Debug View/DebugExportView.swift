import ConvosCore
import SwiftUI

struct DebugExportView: View {
    let environment: AppEnvironment
    let session: any SessionManagerProtocol

    var body: some View {
        List {
            DebugViewSection(environment: environment, session: session)
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
