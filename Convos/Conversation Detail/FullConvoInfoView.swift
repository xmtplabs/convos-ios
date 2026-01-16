import ConvosCore
import SwiftUI

struct FullConvoInfoView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Full")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("This convo has reached its max capacity of \(Conversation.maxMembers) people, so you're unable to invite new people in.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Text("Invitations will be enabled automatically if space becomes available.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            Button {
                onDismiss()
            } label: {
                Text("Got it")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview {
    FullConvoInfoView(onDismiss: {})
        .background(.colorBackgroundRaised)
}
