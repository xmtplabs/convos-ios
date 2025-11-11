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
                Button {
                    deleteAllData()
                } label: {
                    Text("Delete all data")
                }
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorCaution))
                .disabled(viewModel.isDeleting)
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

    private var progressMessage: String {
        guard let currentStep = viewModel.deletionProgress else { return "" }

        switch currentStep {
        case .clearingDeviceRegistration:
            return "Clearing settings..."
        case let .stoppingServices(completed, total):
            return "Stopping services (\(completed)/\(total))..."
        case .deletingFromDatabase:
            return "Deleting database..."
        case .completed:
            return ""
        }
    }

    private func deleteAllData() {
        viewModel.deleteAllData(onComplete: onComplete)
    }
}

#Preview {
    let viewModel = AppSettingsViewModel(session: ConvosClient.mock().session)
    DeleteAllDataView(
        viewModel: viewModel,
        onComplete: {}
    )
}
