import SwiftUI

struct PhotosInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Pics are personal",
            subtitle: "Share faces, places, sensitive or spicy pics with total privacy.",
            paragraphs: [
                .init("Pics are encrypted on send and deleted from temp storage after delivery.", size: .subheadline),
                .init("Convos never sees or saves to your Camera Roll. Image metadata is never shared.", size: .small),
            ],
            primaryButtonAction: { dismiss() },
            learnMoreURL: URL(string: "https://learn.convos.org/pics"),
            showDragIndicator: true
        )
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true

    VStack {
        Button { isPresented.toggle() } label: { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        PhotosInfoSheet()
    }
}
