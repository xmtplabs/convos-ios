import SwiftUI

struct NewConvoIdentityView: View {
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            let action = { openURL(URL(string: "https://learn.convos.org/new-convo-new-identity")!) }
            Button(action: action) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Text("New convo, new everything")
                        .foregroundStyle(.colorTextPrimary)
                    Image(systemName: "info.circle")
                        .foregroundStyle(.colorTextSecondary)
                }
                .font(.footnote)
            }

            Text("For privacy, new members can't see earlier messages.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NewConvoIdentityView()
}
