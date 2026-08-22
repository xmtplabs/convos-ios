#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// What an agent DM shows before it has any messages: what the lane is for,
/// and the shared-memory disclosure (see docs/plans/agent-dms.md).
///
/// This used to be the transcript's first cell, which meant it stayed in the
/// scroll forever. It is centred over the page now and fades out on the first
/// message instead.
///
/// Figma 8069:38615. The three lines step down the iOS type scale - .body,
/// .subheadline, .footnote - with the lower two in secondary.
///
/// Dev-only: when the agent was built on a variant, the shared variant ribbon
/// sits above the title as a badge. Everywhere else the ribbon rides the agent
/// contact card, which a DM deliberately drops - so this is the only place a DM
/// can answer "which runtime am I talking to?". Without it a varianted agent is
/// indistinguishable from a default one until its behavior disagrees.
public struct AgentDmEmptyStateView: View {
    let variant: AgentVariantStamp?
    /// Drops the copy while the keyboard is up - same reason as the group's
    /// empty state. This one is all copy, so it leaves nothing on screen, which
    /// is the point: there is no room for it over the keyboard.
    let hidesText: Bool

    public init(variant: AgentVariantStamp? = nil, hidesText: Bool = false) {
        self.variant = variant
        self.hidesText = hidesText
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // The empty-label guard is not defensive noise: the worker forwards
            // `metadata.variant` verbatim for the cosmetic banner, so a stamp
            // that parseVariantDescriptor would reject still decodes here. Its
            // ribbon would be a bare emoji on a yellow pill - a placeholder that
            // says less than showing nothing.
            if !ConfigManager.shared.currentEnvironment.isProduction,
               let variant, !variant.label.isEmpty {
                AgentVariantRibbon(variant: variant)
                    .fixedSize(horizontal: true, vertical: false)
                    .clipShape(Capsule())
            }
            if !hidesText {
                Text("1:1 with your Agent")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text("Drop anything here, or ask your agent to privately ping other members")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                Text("Everything shared here can be shared with others in the group, so don’t share anything private.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DesignConstants.Spacing.step8x)
    }
}
#endif
