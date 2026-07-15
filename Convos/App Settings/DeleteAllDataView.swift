import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct DeleteAllDataView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @Bindable var viewModel: AppSettingsViewModel
    let onComplete: () -> Void
    @State private var navState: DeleteAllDataNavigatorImpl = .init()
    @State private var navigator: DeleteAllDataCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = DeleteAllDataCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var title: String {
        "Delete everything?"
    }

    var subtitle: String {
        let base = "This will permanently delete all conversations on this device, as well as your profile."
        guard viewModel.currentDeviceIsMain else { return base }
        return base + " This is your main device — the first one created for your account — and other devices pair through it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            if let error = viewModel.deletionError {
                Text("\(error.localizedDescription). Try again.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
            }

            VStack(spacing: DesignConstants.Spacing.step4x) {
                HoldToDeleteButton(
                    isDeleting: viewModel.isDeleting,
                    onDelete: { deleteAllData() }
                )
                .hoverEffect(.lift)

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                }
                .convosButtonStyle(.text)
                .disabled(viewModel.isDeleting)
                .hoverEffect(.lift)
            }

            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .task {
            await viewModel.refreshMainDeviceStatus()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
    }

    private func deleteAllData() {
        viewModel.deleteAllData(onComplete: onComplete)
    }
}

// MARK: - Hold To Delete Button

private struct HoldToDeleteButton: View {
    let isDeleting: Bool
    let onDelete: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        Button {
            onDelete()
        } label: {
            textView
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .disabled(isDeleting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(isDeleting ? "Deleting data" : "Hold to delete all data")
        .accessibilityHint(isDeleting ? "" : "Hold to confirm deletion")
        .accessibilityIdentifier("hold-to-delete-button")
    }

    private var textView: some View {
        ZStack {
            Text("Hold to delete")
                .opacity(isDeleting ? 0 : 1)

            Text("Deleting...")
                .opacity(isDeleting ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: isDeleting)
    }
}

#Preview {
    let viewModel = AppSettingsViewModel(session: ConvosClient.mock().session)
    DeleteAllDataView(
        viewModel: viewModel,
        onComplete: {}
    )
}
