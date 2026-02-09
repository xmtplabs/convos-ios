import ConvosCore
import SwiftUI

struct DebugExportView: View {
    let environment: AppEnvironment

    var body: some View {
        List {
            DebugViewSection(environment: environment)
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Debug")
        .toolbarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { DebugExportView(environment: .tests) }
}
