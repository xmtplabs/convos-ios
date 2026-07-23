import ConvosCore
import SwiftUI

/// The agent-DM disclosure header: always the first cell of an agent-DM
/// transcript, doubling as its empty state. Names the space and carries the
/// shared-memory disclosure (see docs/plans/agent-dms.md).
public struct AgentDmInfoCellView: View {
    let agentProfile: Profile?
    let agentName: String

    public init(agentProfile: Profile?, agentName: String) {
        self.agentProfile = agentProfile
        self.agentName = agentName
    }

    public var body: some View {
        VStack(spacing: 0) {
            avatarCircle
            Text("\(agentName) 1:1 chat")
                .font(.title3)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step6x)
            Text("Chat here to work with \(agentName) without blowing up the groupchat.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.step6x)
            Text("This space is not confidential.")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step6x)
            Text("\(agentName) can share anything it knows.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.step2x)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step8x)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }

    @ViewBuilder
    private var avatarCircle: some View {
        if let agentProfile {
            ProfileAvatarView(
                profile: agentProfile,
                profileImage: nil,
                useSystemPlaceholder: false,
                size: Constant.avatarSize
            )
            .frame(width: Constant.avatarSize, height: Constant.avatarSize)
        } else {
            ZStack {
                Circle()
                    .fill(Color.colorFillTertiary)
                    .frame(width: Constant.avatarSize, height: Constant.avatarSize)
                Text(String(agentName.prefix(1)).uppercased())
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    private enum Constant {
        static let avatarSize: CGFloat = 40.0
    }
}
