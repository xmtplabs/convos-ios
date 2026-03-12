import SwiftUI

struct NewConvoIdentityView: View {
    @State private var presentingInfoSheet: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            let action = { presentingInfoSheet = true }
            Button(action: action) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Text("New convo, new everything")
                        .foregroundStyle(.colorTextPrimary)
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.colorTextTertiary)
                }
                .font(.footnote)
            }

            Text("For privacy, new members can't see earlier messages.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .selfSizingSheet(isPresented: $presentingInfoSheet) {
            NewConvoIdentityInfoSheet()
        }
    }
}

struct NewConvoIdentityInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Private chat for the AI era",
            title: "Every convo is a new world",
            subtitle: "And you're a new you, too.",
            paragraphs: [
                .init("You have Infinite Identities, so you control how you show up, every time.", style: .primary),
                .init("No info is shared between convos, so there's nothing to leak, link or spam.", size: .subheadline),
            ],
            primaryButtonTitle: "Awesome",
            primaryButtonAction: { dismiss() },
            learnMoreTitle: "About infinite identity",
            learnMoreURL: URL(string: "https://learn.convos.org/infinite-identity"),
            showDragIndicator: true
        )
    }
}

#Preview {
    NewConvoIdentityView()
}

#Preview("Info Sheet") {
    @Previewable @State var isPresented: Bool = true
    VStack {
        let action = { isPresented.toggle() }
        Button(action: action) { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        NewConvoIdentityInfoSheet()
    }
}
