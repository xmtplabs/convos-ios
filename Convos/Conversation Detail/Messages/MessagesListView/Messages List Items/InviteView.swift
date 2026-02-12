import ConvosCore
import SwiftUI

struct InviteView: View {
    let invite: Invite

    var body: some View {
        VStack {
            Group {
                if !invite.isEmpty,
                   let inviteURL = invite.inviteURL {
                    QRCodeView(url: inviteURL, backgroundColor: .colorFillMinimal)
                        .frame(maxWidth: 220, maxHeight: 220)
                        .padding(DesignConstants.Spacing.step12x)
                } else {
                    EmptyView()
                        .frame(width: 220, height: 220.0)
                }
            }
            .transition(.blurReplace)
            .background(.colorFillMinimal)
            .mask(RoundedRectangle(cornerRadius: 38.0))
        }
        .id(invite.differenceIdentifier)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conversation invite QR code")
        .accessibilityIdentifier("invite-qr-code")
    }
}

#Preview {
    InviteView(invite: .mock())
}
