import SwiftUI

struct RevealMediaInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Real life is off the record.™")
                .font(.caption)
                .foregroundColor(.colorTextSecondary)
            Text("Reveal")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text("You control when, where and whether media can appear in your convos.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
            Text("Revealing is a personal decision, and the sender will not know your choice.")
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
            .background(.colorBackgroundSurfaceless)
    }
}
