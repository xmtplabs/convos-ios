#if canImport(UIKit)
import SwiftUI

/// Affordance shown under a target message bubble while an agent has an
/// active `convos.org/thinking:1.0` session for it. Mirrors
/// `TypingIndicatorBubbleView`'s bubble shape but with a single steady
/// pulsing dot — "the agent is working on this" rather than "a reply is
/// about to land". The session's `content` (a 3–5 word label like
/// "Searching the web" or "Designing your menu") is rendered underneath
/// the bubble in the same caption style we use elsewhere for secondary
/// metadata.
struct ThinkingIndicatorBubbleView: View {
    let content: String
    var senderName: String?
    /// Suppresses the caption text below the bubble. The thinking detail
    /// sheet renders the content as its own text-message cell above this
    /// bubble, so the caption would just duplicate it.
    var hidesContent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            ThoughtBubble {
                PulsingCircleView.thinkingIndicator
                    .frame(height: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
            }
            if !hidesContent {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.leading, DesignConstants.Spacing.step3x)
            }
        }
        .accessibilityIdentifier("thinking-indicator-bubble")
        .accessibilityLabel("\(senderName ?? "Someone") is thinking: \(content)")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        ThinkingIndicatorBubbleView(content: "Searching the web", senderName: "Cal")
        ThinkingIndicatorBubbleView(content: "Designing your menu", senderName: "Meal planner")
    }
    .padding()
}
#endif
