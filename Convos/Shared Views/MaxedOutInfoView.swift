import SwiftUI

struct MaxedOutInfoView: View {
    let maxNumberOfConvos: Int

    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Maxed out")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text("The app currently supports up to \(maxNumberOfConvos) convos. Consider exploding some to make room for new ones.")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maxed-out-info-view")
    }
}

#Preview {
    MaxedOutInfoView(maxNumberOfConvos: 20)
}
