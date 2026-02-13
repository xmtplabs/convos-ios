import SwiftUI

struct RevealMediaInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Real life is off the record.™")
                .font(.caption)
                .foregroundColor(.colorTextSecondary)
            Text("Reveal")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text("View things when you choose to. Blur or reveal any pic, anytime.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
            Text("Revealing is a personal preference, and no one else in the convo will know your choice.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                Button {
                    // swiftlint:disable:next force_unwrapping
                    openURL(URL(string: "https://learn.convos.org/reveal")!)
                } label: {
                    Text("Learn more")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview {
    @Previewable @State var isPresented = true

    VStack {
        Button {
            isPresented.toggle()
        } label: {
            Text("Show Sheet")
        }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        RevealMediaInfoSheet()
    }
}
