#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct ClusteredAvatarView: View {
    let members: [ClusteredAvatarMember]
    /// When set, the cluster lays out at this exact side length without a
    /// `GeometryReader`. The cluster nests one sub-avatar per member, so the
    /// self-sizing path otherwise stacks ~N+1 geometry-feedback passes per
    /// cell during scroll. Nil keeps the self-sizing path.
    var size: CGFloat?

    private let containerBase: CGFloat = 44.0

    public init(members: [ClusteredAvatarMember], size: CGFloat? = nil) {
        self.members = members
        self.size = size
    }

    public var body: some View {
        if let size {
            clusterContent(side: size).accessibilityHidden(true)
        } else {
            GeometryReader { geometry in
                clusterContent(side: min(geometry.size.width, geometry.size.height))
            }
            .aspectRatio(1.0, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func clusterContent(side: CGFloat) -> some View {
        let scale = side / containerBase
        ZStack {
            switch members.count {
            case 0:
                MonogramView(name: "", size: side)
            case 1:
                singleAvatar(member: members[0], size: side)
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

    @ViewBuilder
    private func singleAvatar(member: ClusteredAvatarMember, size: CGFloat) -> some View {
        ProfileAvatarView(
            profile: member.profile,
            profileImage: nil,
            useSystemPlaceholder: false,
            agentVerification: member.agentVerification,
            size: size
        )
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func twoAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 23 * scale)
            .offset(x: -5.5 * scale, y: -5.5 * scale)

        avatarCircle(member: members[1], size: 14 * scale)
            .offset(x: 9 * scale, y: 9 * scale)
    }

    @ViewBuilder
    private func threeAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(member: members[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(member: members[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)
    }

    @ViewBuilder
    private func fourAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(member: members[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(member: members[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(member: members[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)
    }

    @ViewBuilder
    private func fiveAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(member: members[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(member: members[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(member: members[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)

        avatarCircle(member: members[4], size: 8 * scale)
            .offset(x: -14.5 * scale, y: 7 * scale)
    }

    @ViewBuilder
    private func sixAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(member: members[1], size: 16 * scale)
            .offset(x: 10.81 * scale, y: 3.89 * scale)

        avatarCircle(member: members[2], size: 14 * scale)
            .offset(x: -3.57 * scale, y: 12.49 * scale)

        avatarCircle(member: members[3], size: 10 * scale)
            .offset(x: 9.81 * scale, y: -10.27 * scale)

        avatarCircle(member: members[4], size: 8 * scale)
            .offset(x: -14.5 * scale, y: 7 * scale)

        avatarCircle(member: members[5], size: 5 * scale)
            .offset(x: 3.5 * scale, y: -17 * scale)
    }

    @ViewBuilder
    private func sevenAvatarLayout(scale: CGFloat) -> some View {
        avatarCircle(member: members[0], size: 21 * scale)
            .offset(x: -6.5 * scale, y: -6.5 * scale)

        avatarCircle(member: members[1], size: 16 * scale)
            .offset(x: 9.81 * scale, y: 6.04 * scale)

        avatarCircle(member: members[2], size: 11 * scale)
            .offset(x: 10.5 * scale, y: -8.29 * scale)

        avatarCircle(member: members[3], size: 10 * scale)
            .offset(x: -11.01 * scale, y: 10.25 * scale)

        avatarCircle(member: members[4], size: 8 * scale)
            .offset(x: 1 * scale, y: 15.75 * scale)

        avatarCircle(member: members[5], size: 5 * scale)
            .offset(x: 4.31 * scale, y: -16.29 * scale)

        avatarCircle(member: members[6], size: 5 * scale)
            .offset(x: -2.09 * scale, y: 7.88 * scale)
    }

    @ViewBuilder
    private func avatarCircle(member: ClusteredAvatarMember, size: CGFloat) -> some View {
        ProfileAvatarView(
            profile: member.profile,
            profileImage: nil,
            useSystemPlaceholder: false,
            agentVerification: member.agentVerification,
            size: size
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.colorBorderEdge, lineWidth: 1)
        }
    }
}

#Preview {
    let members: [ClusteredAvatarMember] = [
        ClusteredAvatarMember(
            profile: Profile(
                inboxId: "1",
                conversationId: "preview",
                name: "Convos Agent",
                avatar: nil,
                isAgent: true,
                metadata: ["emoji": .string("🤖")]
            ),
            agentVerification: .verified(.convos)
        ),
        ClusteredAvatarMember(profile: .mock(inboxId: "2", name: "Bob")),
        ClusteredAvatarMember(profile: .mock(inboxId: "3", name: "Carol")),
        ClusteredAvatarMember(profile: .mock(inboxId: "4", name: "Dave")),
        ClusteredAvatarMember(profile: .mock(inboxId: "5", name: "Eve")),
        ClusteredAvatarMember(profile: .mock(inboxId: "6", name: "Frank")),
        ClusteredAvatarMember(profile: .mock(inboxId: "7", name: "Grace")),
    ]

    VStack(spacing: 16) {
        HStack(spacing: 16) {
            ClusteredAvatarView(members: Array(members.prefix(1)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: Array(members.prefix(2)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: Array(members.prefix(3)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: Array(members.prefix(4)))
                .frame(width: 44, height: 44)
        }
        HStack(spacing: 16) {
            ClusteredAvatarView(members: Array(members.prefix(5)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: Array(members.prefix(6)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: Array(members.prefix(7)))
                .frame(width: 44, height: 44)
            ClusteredAvatarView(members: members)
                .frame(width: 56, height: 56)
        }
    }
    .padding()
}
#endif
