import ConvosCore
import ConvosMetrics
import SwiftUI

struct AgentPowerInfoView: View {
    let creatorName: String
    let agentName: String

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    @State private var navState: AgentPowerInfoNavigatorImpl = .init()
    @State private var navigator: AgentPowerInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = AgentPowerInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            TightLineHeightText(text: "You power your agents", fontSize: 40, lineHeight: 40)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Agents use Power to think and act")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("If they run out of power credits, they switch into read-only mode.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("An agent's creator controls its power")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("\(creatorName) can restore power to \(agentName)")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            let viewUsageAction = { dismiss() }
            Button(action: viewUsageAction) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.colorLava)
                    Text("View your usage")
                }
                .font(.body)
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding(.horizontal, DesignConstants.Spacing.step10x)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, horizontalSizeClass == .regular
            ? DesignConstants.Spacing.step10x
            : DesignConstants.Spacing.step6x)
        .presentationBackground(.colorBackgroundRaised)
        .sheetDragIndicator(.hidden)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    let showAction = { isPresented.toggle() }
    VStack {
        Button(action: showAction) { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        AgentPowerInfoView(creatorName: "Quarter", agentName: "Hoodrat")
    }
}
