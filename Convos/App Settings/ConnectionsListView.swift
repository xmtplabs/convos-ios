import ConvosConnections
import ConvosCore
import SwiftUI

struct ConnectionsListView: View {
    @Bindable var viewModel: ConnectionsListViewModel

    var body: some View {
        List {
            headerSection

            connectionsSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .task {
            viewModel.refresh()
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Connections")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text("Share services with conversations")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    private var connectionsSection: some View {
        Section {
            ForEach(viewModel.rows) { row in
                FeatureRowItem(
                    imageName: nil,
                    symbolName: symbolName(for: row),
                    title: row.title,
                    subtitle: row.subtitle,
                    iconBackgroundColor: .colorFillMinimal,
                    iconForegroundColor: .colorTextPrimary
                ) {
                    Toggle("", isOn: Binding(
                        get: { row.isOn },
                        set: { _ in viewModel.toggle(row) }
                    ))
                    .labelsHidden()
                    .disabled(viewModel.isConnecting || !row.isToggleEnabled)
                }
            }
        }
    }

    private func symbolName(for row: ConnectionsListViewModel.Row) -> String {
        switch row.source {
        case .cloud(let service, _):
            return service.iconSystemName
        case .device(let kind, _):
            return kind.systemImageName
        }
    }
}
