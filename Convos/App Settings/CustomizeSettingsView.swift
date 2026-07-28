import ConvosComposer
import ConvosMetrics
import SwiftUI

struct CustomizeSettingsView: View {
    @Bindable private var defaults: GlobalConvoDefaults = .shared
    @State private var navState: CustomizeSettingsNavigatorImpl = .init()
    @State private var navigator: CustomizeSettingsCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = CustomizeSettingsCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Customize")
                        .convosTextStyle(.display)
                    Text("Your new convos")
                        .convosTextStyle(.supportingPrimary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
            .listRowSpacing(0.0)
            .listRowInsets(.all, DesignConstants.Spacing.step2x)
            .listSectionMargins(.top, 0.0)
            .listSectionSeparator(.hidden)

            Section {
                customizeToggleRow(
                    symbolName: "qrcode",
                    title: "Include info with invites",
                    subtitle: "When enabled, anyone with your convo code can see its pic, name and description",
                    isOn: $defaults.includeInfoWithInvites,
                    toggleAccessibilityIdentifier: "customize-include-info-toggle"
                )

                customizeToggleRow(
                    symbolName: "eye",
                    title: "Read receipts",
                    subtitle: "Let others know when you've read their messages",
                    isOn: $defaults.sendReadReceipts,
                    toggleAccessibilityIdentifier: "read-receipts-toggle"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
    }

    @ViewBuilder
    private func customizeToggleRow(
        symbolName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        toggleAccessibilityIdentifier: String
    ) -> some View {
        ConvosSettingsRow(
            iconSystemName: symbolName,
            title: title,
            subtitle: subtitle
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityIdentifier(toggleAccessibilityIdentifier)
        }
    }
}

#Preview {
    NavigationStack {
        CustomizeSettingsView()
    }
}
