import ConvosCore
import SwiftUI

enum BubbleCorner: Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

enum LiveBubbleStyle: Hashable {
    /// User's own bubble — saturated accent, white text.
    case user
    /// The focused member's bubble — incoming/pastel.
    case focusedMember
    /// Other (non-focused) members' bubble — incoming/pastel.
    case otherMember
}

/// Read-only Honk-style live bubble. Renders a single block of text inside
/// a rounded shape with one tail corner. Used for the focused member's
/// bubble (top region) and for the chorus of other members (bottom region).
///
/// The user's own bubble doubles as the input field, so it uses the
/// `LiveBubbleEditor` companion view (next file) rather than this read-only
/// variant.
struct LiveBubble: View {
    let text: String
    let style: LiveBubbleStyle
    let tailCorner: BubbleCorner
    let cornerRadius: CGFloat

    init(
        text: String,
        style: LiveBubbleStyle,
        tailCorner: BubbleCorner,
        cornerRadius: CGFloat = Constant.bubbleCornerRadius
    ) {
        self.text = text
        self.style = style
        self.tailCorner = tailCorner
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            background
            content
        }
        .compositingGroup()
        .mask(maskShape)
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        switch style {
        case .user:
            Color.colorBubble
        case .focusedMember, .otherMember:
            Color.colorBubbleIncoming
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Text(text)
            .font(.system(.title, weight: .semibold))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.vertical, DesignConstants.Spacing.step6x)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: text)
    }

    private var textColor: Color {
        switch style {
        case .user:
            return .colorTextPrimaryInverted
        case .focusedMember, .otherMember:
            return .colorTextPrimary
        }
    }

    // MARK: - Mask

    private var maskShape: UnevenRoundedRectangle {
        let small: CGFloat = 4.0
        let big: CGFloat = cornerRadius
        switch tailCorner {
        case .topLeading:
            return .rect(
                topLeadingRadius: small,
                bottomLeadingRadius: big,
                bottomTrailingRadius: big,
                topTrailingRadius: big
            )
        case .topTrailing:
            return .rect(
                topLeadingRadius: big,
                bottomLeadingRadius: big,
                bottomTrailingRadius: big,
                topTrailingRadius: small
            )
        case .bottomLeading:
            return .rect(
                topLeadingRadius: big,
                bottomLeadingRadius: small,
                bottomTrailingRadius: big,
                topTrailingRadius: big
            )
        case .bottomTrailing:
            return .rect(
                topLeadingRadius: big,
                bottomLeadingRadius: big,
                bottomTrailingRadius: small,
                topTrailingRadius: big
            )
        }
    }
}

#Preview("focused member, top-trailing tail") {
    LiveBubble(
        text: "Tell me what kind of assistant you want to build.",
        style: .focusedMember,
        tailCorner: .topTrailing
    )
    .padding()
    .frame(height: 360)
}

#Preview("user, bottom-trailing tail (read-only)") {
    LiveBubble(
        text: "I want one that helps me remember things.",
        style: .user,
        tailCorner: .bottomTrailing
    )
    .padding()
    .frame(height: 280)
}
