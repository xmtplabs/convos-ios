import ConvosCore
import SwiftUI

struct FullConvoInfoView: View {
    let onDismiss: () -> Void

    var body: some View {
        FeatureInfoSheet(
            title: "Full",
            paragraphs: [
                .init("This convo has reached its max capacity of \(Conversation.maxMembers) people, so you're unable to invite new people in.", style: .primary),
                .init("Invitations will be enabled automatically if space becomes available."),
            ],
            primaryButtonAction: { onDismiss() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("full-convo-info-view")
    }
}

#Preview {
    FullConvoInfoView(onDismiss: {})
        .background(.colorBackgroundSurfaceless)
}
