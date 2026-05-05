import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            placeholderBody
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                        .accessibilityIdentifier("close-assistant-builder")
                    }
                }
                .background(.colorBackgroundSurfaceless)
        }
        .interactiveDismissDisabled()
        .onAppear {
            viewModel.setDismissAction(dismiss)
        }
    }

    @ViewBuilder
    private var placeholderBody: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Assistant Builder")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("Phase: \(String(describing: viewModel.phase))")
                .font(.system(.subheadline))
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var presented: Bool = true
    let viewModel = AssistantBuilderViewModel(session: ConvosClient.mock().session)
    VStack {}
        .sheet(isPresented: $presented) {
            AssistantBuilderView(viewModel: viewModel)
        }
}
