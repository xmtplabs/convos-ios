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
///
/// Dev-only: when the agent was built on a variant, the shared variant ribbon
/// sits above the title as a badge. Everywhere else the ribbon rides the agent
/// contact card, which a DM deliberately drops - so this header is the only
/// place a DM can answer "which runtime am I talking to?". Without it a
/// varianted agent is indistinguishable from a default one until its behavior
/// disagrees, which is the whole failure mode the variant work exists to close.
public struct AgentDmInfoCellView: View {
    let agentName: String
    let variant: AgentVariantStamp?

    public init(agentName: String, variant: AgentVariantStamp? = nil) {
        self.agentName = agentName
        self.variant = variant
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if !ConfigManager.shared.currentEnvironment.isProduction, let variant {
                // Sized to its content and centered, rather than the full-bleed
                // bar the contact-card overlay uses: this header is a centered
                // column, and a full-width left-aligned bar would read as a
                // banner across the screen instead of a badge on the agent.
                AgentVariantRibbon(variant: variant)
                    .fixedSize(horizontal: true, vertical: false)
                    .clipShape(Capsule())
            }
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
