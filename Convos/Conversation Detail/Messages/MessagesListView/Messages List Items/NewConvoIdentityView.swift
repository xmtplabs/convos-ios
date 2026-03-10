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
                .padding(.top, 20)
        }
    }
}

struct NewConvoIdentityInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "New convo, new everything",
            paragraphs: [
                .init("Every convo gives you a fresh cryptographic identity. No one can link your conversations together."),
                .init("New members can't see earlier messages, and leaving a convo destroys your identity in it.", size: .subheadline),
            ],
            primaryButtonAction: { dismiss() },
            learnMoreURL: URL(string: "https://learn.convos.org/new-convo-new-identity")
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
            .padding(.top, 20)
    }
}
