import ConvosCore
import SwiftUI

struct ReadReceiptAvatarsView: View {
    let profiles: [Profile]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                ForEach(profiles) { profile in
                    ProfileAvatarView(
                        profile: profile,
                        profileImage: nil,
                        useSystemPlaceholder: false
                    )
                    .frame(width: 16, height: 16)
                }
            }
        }
        .frame(maxWidth: 120)
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: DesignConstants.Spacing.stepX)
                Rectangle().fill(.black)
                LinearGradient(
                    gradient: Gradient(colors: [.black, .clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: DesignConstants.Spacing.stepX)
            }
        )
        .accessibilityIdentifier("read-receipt-avatars")
    }
}
