#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// The agent-DM disclosure header: always the first cell of an agent-DM
/// transcript, doubling as its empty state. Names the agent, says what the
/// lane is for, and carries the shared-memory disclosure (see
/// docs/plans/agent-dms.md).
///
/// Figma 7686:39662. The three lines step down the iOS type scale -
/// .body medium, .subheadline, .footnote - with the disclosure in secondary.
public struct AgentDmInfoCellView: View {
    let agentName: String

    public init(agentName: String) {
        self.agentName = agentName
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text("1-on-1 with \(agentName)")
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
            Text("Chat here to update Home, ping members, or check in without blowing up the groupchat.")
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
            Text("Everything shared here can be shared with everyone in the group, so don’t share anything private.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Constant.verticalPadding)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }

    private enum Constant {
        /// Keeps the header clear of the nav chrome above and the first
        /// message below; off the shared scale, which steps 48 to 64.
        static let verticalPadding: CGFloat = 52.0
    }
}
#endif
