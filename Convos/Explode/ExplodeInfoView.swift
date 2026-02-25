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
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Exploding convos",
            paragraphs: [
                .init("Messages and Members are destroyed forever, and there's no record that the convo ever happened."),
            ],
            primaryButtonAction: { dismiss() }
        )
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
