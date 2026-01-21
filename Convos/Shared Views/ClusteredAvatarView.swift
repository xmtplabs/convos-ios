import ConvosCore
import SwiftUI

struct ClusteredAvatarView: View {
    let profiles: [Profile]

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let scale = side / 56.0

            ZStack {
                if profiles.isEmpty {
                    MonogramView(name: "")
                } else if profiles.count == 1 {
                    singleAvatar(profile: profiles[0], size: side)
                } else if profiles.count == 2 {
                    twoAvatarLayout(scale: scale)
                } else {
                    threeAvatarLayout(scale: scale)
                }
            }
            .frame(width: side, height: side)
            .background(.colorFillMinimal)
            .clipShape(Circle())
        }
        .aspectRatio(1.0, contentMode: .fit)
    }

    @ViewBuilder
    private func singleAvatar(profile: Profile, size: CGFloat) -> some View {
        ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func twoAvatarLayout(scale: CGFloat) -> some View {
        let mainSize = 25.2 * scale
        let smallSize = 16.8 * scale

        avatarCircle(profile: profiles[0], size: mainSize)
            .offset(x: (8.5 - 28) * scale, y: (7 - 28) * scale)

        avatarCircle(profile: profiles[1], size: smallSize)
            .offset(x: (35.1 - 28) * scale, y: (22.4 - 28) * scale)
    }

    @ViewBuilder
    private func threeAvatarLayout(scale: CGFloat) -> some View {
        let mainSize = 25.2 * scale
        let smallSize = 16.8 * scale

        avatarCircle(profile: profiles[0], size: mainSize)
            .offset(x: (8.5 - 28) * scale, y: (7 - 28) * scale)

        avatarCircle(profile: profiles[1], size: smallSize)
            .offset(x: (16.9 - 28) * scale, y: (35 - 28) * scale)

        avatarCircle(profile: profiles[2], size: smallSize)
            .offset(x: (35.1 - 28) * scale, y: (22.4 - 28) * scale)
    }

    @ViewBuilder
    private func avatarCircle(profile: Profile, size: CGFloat) -> some View {
        ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(.colorBorderSubtle, lineWidth: 1)
            }
    }
}

#Preview {
    let profiles: [Profile] = [
        .mock(inboxId: "1", name: "Alice"),
        .mock(inboxId: "2", name: "Bob"),
        .mock(inboxId: "3", name: "Carol"),
    ]

    VStack(spacing: 16) {
        ClusteredAvatarView(profiles: Array(profiles.prefix(1)))
            .frame(width: 56, height: 56)

        ClusteredAvatarView(profiles: Array(profiles.prefix(2)))
            .frame(width: 56, height: 56)

        ClusteredAvatarView(profiles: profiles)
            .frame(width: 56, height: 56)

        ClusteredAvatarView(profiles: profiles)
            .frame(width: 96, height: 96)
    }
    .padding()
}
