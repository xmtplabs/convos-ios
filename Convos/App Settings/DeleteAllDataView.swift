import ConvosCore
import SwiftUI

struct DeleteAllDataView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @Bindable var viewModel: AppSettingsViewModel
    let onComplete: () -> Void

    var title: String {
        "Delete everything?"
    }

    var subtitle: String {
        "This will permanently delete all conversations on this device, as well as your Quickname."
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
