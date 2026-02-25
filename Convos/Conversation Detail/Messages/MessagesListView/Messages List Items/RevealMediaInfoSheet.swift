import SwiftUI

struct RevealMediaInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Reveal",
            subtitle: "View things when you choose to. Blur or reveal any pic, anytime.",
            paragraphs: [
                .init("Revealing is a personal preference, and no one else in the convo will know your choice."),
            ],
            primaryButtonAction: { dismiss() },
            learnMoreURL: URL(string: "https://learn.convos.org/reveal")
        )
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true

    VStack {
        Button { isPresented.toggle() } label: { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        RevealMediaInfoSheet()
    }
}
