#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// The shared dev-only variant ribbon: `🧪 <label> · PR #<n>` on a soft yellow
/// surface, with the PR number linking to the pull request. Rendered as a plain
/// rectangle; the host shapes its corners. Used in two places so they read as
/// the same thing: overlaid across the top of the in-chat agent contact card
/// (clipped to the card's top corners), and as the header of the agent
/// profile's variant card, with the full what-to-test expanded below it.
struct AgentVariantRibbon: View {
    let variant: AgentVariantStamp
    /// Vertical inset of the ribbon bar. The in-chat overlay uses a tighter
    /// value so more of the contact card's top padding stays visible beneath it.
    var verticalPadding: CGFloat = DesignConstants.Spacing.step2x

    var body: some View {
        let prURL: URL? = variant.prUrl.flatMap { URL(string: $0) }
        let prNumber: String? = variant.prUrl.flatMap { Self.prNumber(from: $0) }
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            Text("🧪 \(variant.label)")
                .lineLimit(1)
            if let prURL, let prNumber {
                Text("·")
                    .foregroundStyle(.colorTextSecondary)
                Link("PR #\(prNumber)", destination: prURL)
                    .lineLimit(1)
            }
            Spacer(minLength: 0.0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.colorTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, verticalPadding)
        .background(.colorWarning.opacity(0.18))
    }

    static func prNumber(from prUrl: String) -> String? {
        guard let number = prUrl.split(separator: "/").last, !number.isEmpty else { return nil }
        return String(number)
    }
}

/// The agent profile's variant card: the shared `AgentVariantRibbon` as a header
/// (so it matches the in-chat ribbon) plus the full what-to-test below. Dev-only;
/// gated to non-production at the call site.
public struct ConversationVariantBanner: View {
    let variant: AgentVariantStamp

    public init(variant: AgentVariantStamp) {
        self.variant = variant
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            AgentVariantRibbon(variant: variant)
            Text(variant.whatToTest)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignConstants.Spacing.step4x)
        }
        .background(Color.colorBackgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Variant \(variant.label). \(variant.whatToTest)")
    }
}

#Preview {
    VStack(spacing: 24) {
        AgentVariantRibbon(
            variant: AgentVariantStamp(
                slug: "pr-1234", label: "Mixture of Agents",
                whatToTest: "Every reply runs through Mixture of Agents.",
                prUrl: "https://github.com/xmtplabs/convos-assistants/pull/2334"
            )
        )
        ConversationVariantBanner(
            variant: AgentVariantStamp(
                slug: "pr-1234", label: "Mixture of Agents",
                whatToTest: "Every reply runs through Mixture of Agents — GLM-5.2 + DeepSeek V4 Pro + Kimi K2.6 synthesized by a Claude Opus 4.8 aggregator.",
                prUrl: "https://github.com/xmtplabs/convos-assistants/pull/2334"
            )
        )
    }
    .padding()
    .background(Color.colorBackgroundRaisedSecondary)
}
#endif
