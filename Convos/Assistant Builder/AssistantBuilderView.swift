import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            canvas
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                        .accessibilityIdentifier("close-assistant-builder")
                    }
                }
                .background(.colorBackgroundSurfaceless)
                .selfSizingSheet(isPresented: bootstrapSheetBinding) {
                    CLIBootstrapSheet(viewModel: viewModel)
                }
        }
        .interactiveDismissDisabled()
        .onAppear {
            viewModel.setDismissAction(dismiss)
        }
    }

    private var bootstrapSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.phase == .bootstrap },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var canvas: some View {
        switch viewModel.phase {
        case .bootstrap:
            placeholderCanvas
        case .focus:
            focusModePlaceholder
        case .stopped:
            stoppedPlaceholder
        }
    }

    @ViewBuilder
    private var placeholderCanvas: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("New Assistant")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("Setting up your conversation…")
                .font(.system(.subheadline))
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var focusModePlaceholder: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Focus mode active")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            if let focusedInboxId = viewModel.focusSession?.focusedInboxId {
                Text("Focused on: \(focusedInboxId.prefix(8))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stoppedPlaceholder: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Text("Session ended")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("Tap to start chatting (placeholder)")
                .font(.subheadline)
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
