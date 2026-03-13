import SwiftUI

struct TypingIndicatorBubbleView: View {
    var body: some View {
        MessageContainer(style: .tailed, isOutgoing: false) {
            PulsingCircleView.typingIndicator
                .frame(height: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, 10.0)
        }
        .accessibilityIdentifier("typing-indicator-bubble")
    }
}

#Preview {
    TypingIndicatorBubbleView()
        .padding()
}
