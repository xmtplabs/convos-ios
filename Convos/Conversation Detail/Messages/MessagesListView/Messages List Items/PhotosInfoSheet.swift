import SwiftUI

struct PhotosInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Pics are personal",
            subtitle: "Share faces, places, spicy and confidential info with total privacy.",
            paragraphs: [
                .init("When you send a pic, Convos removes its metadata, encrypts it, and deletes it from the network once it's delivered.", size: .subheadline),
                .init("Convos never asks to see your Camera Roll and never saves anything to your device.", size: .small),
            ],
            primaryButtonAction: { dismiss() },
            learnMoreURL: URL(string: "https://learn.convos.org/photos")
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
