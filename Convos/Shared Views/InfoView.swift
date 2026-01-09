import SwiftUI

struct InfoView: View {
    let title: String
    let description: String
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text(description)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    if let onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
                } label: {
                    Text("Got it")
                }
                .convosButtonStyle(.rounded(fullWidth: true))
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview {
    InfoView(title: "Invalid invite", description: "Looks like this invite isn't active anymore.")
}
