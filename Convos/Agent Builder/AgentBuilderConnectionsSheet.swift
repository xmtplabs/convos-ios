import ConvosCore
import SwiftUI

/// Self-sizing sheet content presented from the Agent Builder's
/// `batteryblock.fill` connections button. Each row reuses
/// `FeatureRowItem` (same styling as `ConversationConnectionsSection`'s
/// list) and toggling drives the corresponding chip in the composer's
/// attachments row.
struct AgentBuilderConnectionsSheet: View {
    @Bindable var viewModel: AgentBuilderViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Connections")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .padding(.bottom, DesignConstants.Spacing.step2x)

            VStack(spacing: 0) {
                ForEach(Array(AgentBuilderConnection.supportedCases.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 {
                        Divider()
                            .padding(.leading, DesignConstants.Spacing.step10x + DesignConstants.Spacing.step4x)
                    }
                    FeatureRowItem(
                        imageName: nil,
                        symbolName: connection.rowSymbolName,
                        title: connection.displayName,
                        subtitle: connection.subtitle,
                        iconBackgroundColor: .colorFillMinimal,
                        iconForegroundColor: .colorTextPrimary
                    ) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.enabledConnections.contains(connection) },
                            set: { _ in viewModel.toggleConnection(connection) }
                        ))
                        .labelsHidden()
                        .disabled(viewModel.isConnectingCloud)
                    }
                    .padding(DesignConstants.Spacing.step3x)
                }
            }
            .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.regular))
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
    }
}

#Preview {
    @Previewable @State var presented: Bool = true
    @Previewable @State var viewModel: AgentBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    VStack {}
        .selfSizingSheet(isPresented: $presented) {
            AgentBuilderConnectionsSheet(viewModel: viewModel)
        }
}
