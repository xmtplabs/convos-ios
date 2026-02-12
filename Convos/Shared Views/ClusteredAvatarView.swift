import ConvosCore
import SwiftUI

struct ClusteredAvatarView: View {
    let profiles: [Profile]

    private let containerBase: CGFloat = 44.0

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let scale = side / containerBase

            ZStack {
                switch profiles.count {
                case 0:
                    MonogramView(name: "")
                case 1:
                    singleAvatar(profile: profiles[0], size: side)
                case 2:
                    twoAvatarLayout(scale: scale)
                case 3:
                    threeAvatarLayout(scale: scale)
                case 4:
                    fourAvatarLayout(scale: scale)
                case 5:
                    fiveAvatarLayout(scale: scale)
                case 6:
                    sixAvatarLayout(scale: scale)
                default:
                    sevenAvatarLayout(scale: scale)
                }
            }
            .frame(width: side, height: side)
            .background(.colorFillMinimal)
            .clipShape(Circle())
        }
        .aspectRatio(1.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func singleAvatar(profile: Profile, size: CGFloat) -> some View {
        ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func twoAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 23 * scale)
            .offset(x: -5.5 * scale, y: -5.5 * scale)

        avatarCircle(profile: profiles[1], size: 14 * scale)
            .offset(x: 9 * scale, y: 9 * scale)
    }

    @ViewBuilder
    private func threeAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(profile: profiles[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(profile: profiles[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)
    }

    @ViewBuilder
    private func fourAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(profile: profiles[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(profile: profiles[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(profile: profiles[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)
    }

    @ViewBuilder
    private func fiveAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(profile: profiles[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(profile: profiles[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(profile: profiles[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)

        avatarCircle(profile: profiles[4], size: 8 * scale)
            .offset(x: -14.5 * scale, y: 7 * scale)
    }

    @ViewBuilder
    private func sixAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(profile: profiles[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(profile: profiles[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(profile: profiles[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)

        avatarCircle(profile: profiles[4], size: 8 * scale)
            .offset(x: -14.5 * scale, y: 7 * scale)

        avatarCircle(profile: profiles[5], size: 5 * scale)
            .offset(x: 3.5 * scale, y: -17 * scale)
    }

    @ViewBuilder
    private func sevenAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(profile: profiles[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(profile: profiles[1], size: 16 * scale)
            .offset(x: 9.81 * scale, y: 6.04 * scale)

        avatarCircle(profile: profiles[2], size: 11 * scale)
            .offset(x: 10.5 * scale, y: -8.29 * scale)

        avatarCircle(profile: profiles[3], size: 10 * scale)
            .offset(x: -11.01 * scale, y: 10.25 * scale)

        avatarCircle(profile: profiles[4], size: 8 * scale)
            .offset(x: 1 * scale, y: 15.75 * scale)

        avatarCircle(profile: profiles[5], size: 5 * scale)
            .offset(x: 4.31 * scale, y: -16.29 * scale)

        avatarCircle(profile: profiles[6], size: 5 * scale)
            .offset(x: -2.09 * scale, y: 7.88 * scale)
    }

    @ViewBuilder
    private func avatarCircle(profile: Profile, size: CGFloat) -> some View {
        ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(.colorBorderEdge, lineWidth: 1)
            }
    }
}

#Preview {
    let profiles: [Profile] = [
        .mock(inboxId: "1", name: "Alice"),
        .mock(inboxId: "2", name: "Bob"),
        .mock(inboxId: "3", name: "Carol"),
        .mock(inboxId: "4", name: "Dave"),
        .mock(inboxId: "5", name: "Eve"),
        .mock(inboxId: "6", name: "Frank"),
        .mock(inboxId: "7", name: "Grace"),
    ]

    VStack(spacing: 16) {
        HStack(spacing: 16) {
            ClusteredAvatarView(profiles: Array(profiles.prefix(1)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: Array(profiles.prefix(2)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: Array(profiles.prefix(3)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: Array(profiles.prefix(4)))
                .frame(width: 44, height: 44)
        }
        HStack(spacing: 16) {
            ClusteredAvatarView(profiles: Array(profiles.prefix(5)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: Array(profiles.prefix(6)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: Array(profiles.prefix(7)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(profiles: profiles)
                .frame(width: 56, height: 56)
        }
    }
    .padding()
}
