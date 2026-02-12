import SwiftUI

struct SoonLabel: View {
    var body: some View {
        Text("Soon")
            .font(.subheadline)
            .foregroundStyle(.colorTextTertiary)
            .padding(.vertical, 6.0)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: DesignConstants.Spacing.step8x)
            .background(
                Capsule()
                    .fill(.colorFillMinimal)
            )
            .accessibilityLabel("Coming soon")
    }
}

struct ExplodeInfoView: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Real life is off the record.™")
                .font(.caption)
                .foregroundColor(.colorTextSecondary)
            Text("Exploding convos")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text("Messages and Members are destroyed forever, and there’s no record that the convo ever happened.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                }
                .convosButtonStyle(.rounded(fullWidth: true))
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explode-info-view")
    }
}

#Preview {
    @Previewable @State var presentingExplodeInfo: Bool = false
    VStack {
        Button {
            presentingExplodeInfo.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presentingExplodeInfo) {
        ExplodeInfoView()
    }
}
