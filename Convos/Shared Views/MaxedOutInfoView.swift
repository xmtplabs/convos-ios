import SwiftUI

struct MaxedOutInfoView: View {
    let maxNumberOfConvos: Int

    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            title: "Maxed out",
            paragraphs: [
                .init("The app currently supports up to \(maxNumberOfConvos) convos. Consider exploding some to make room for new ones."),
            ],
            primaryButtonAction: { dismiss() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maxed-out-info-view")
    }
}

#Preview {
    MaxedOutInfoView(maxNumberOfConvos: 20)
}
