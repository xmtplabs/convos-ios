#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// The agent-DM disclosure header: always the first cell of an agent-DM
/// transcript, doubling as its empty state. Names the agent, says what the
/// lane is for, and carries the shared-memory disclosure (see
/// docs/plans/agent-dms.md).
public struct AgentDmInfoCellView: View {
    let agentName: String

    public init(agentName: String) {
        self.agentName = agentName
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("1-on-1 with \(agentName)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text("Chat here to update Home, ping members, or check in without blowing up the groupchat.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step6x)
            Text("Everything shared here can be shared with everyone in the group, so don't share anything private.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step6x)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step8x)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }
}
#endif
