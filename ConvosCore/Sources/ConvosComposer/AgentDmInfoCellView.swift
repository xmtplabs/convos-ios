import ConvosCore
import SwiftUI

/// The agent-DM disclosure header: always the first cell of an agent-DM
/// transcript, doubling as its empty state. Names the space and carries the
/// shared-memory disclosure (see docs/plans/agent-dms.md).
public struct AgentDmInfoCellView: View {
    let agentName: String

    public init(agentName: String) {
        self.agentName = agentName
    }

    public var body: some View {
        VStack(spacing: 0) {
            avatarCircle
            Text("\(agentName) 1:1 chat")
                .font(.title3)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step4x)
            Text("Chat here to work with \(agentName) without blowing up the groupchat.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.step5x)
            Text("This space is not confidential.")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step5x)
            Text("\(agentName) can share anything it knows.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.stepX)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step8x)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }

    private var avatarCircle: some View {
        ZStack {
            Circle()
                .fill(Color.colorFillTertiary)
                .frame(width: 56.0, height: 56.0)
            Text(String(agentName.prefix(1)).uppercased())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
        }
    }
}
