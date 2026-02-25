import SwiftUI

struct InfoView: View {
    let title: String
    let description: String
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            title: title,
            paragraphs: [
                .init(description),
            ],
            primaryButtonAction: {
                if let onDismiss {
                    onDismiss()
                } else {
                    dismiss()
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info-view")
    }
}

#Preview {
    InfoView(title: "Invalid invite", description: "Looks like this invite isn't active anymore.")
}
