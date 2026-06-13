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

/// Two height modes for any bubble. `.full` is the Honk-canvas presentation.
/// `.singleLine` is the compact "I'm here / I have text" pill — text gets
/// head-truncated to one line, dot indicators (if any) sit on the same row.
enum LiveBubbleSize: Hashable {
    case full
    case singleLine
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
    let agentVerification: AgentVerification
    let size: LiveBubbleSize
    let isPlaceholder: Bool

    @State private var placeholderPulsed: Bool = false

    init(
        text: String,
        style: LiveBubbleStyle,
        tailCorner: BubbleCorner,
        cornerRadius: CGFloat = Constant.bubbleCornerRadius,
        agentVerification: AgentVerification = .unverified,
        size: LiveBubbleSize = .full,
        isPlaceholder: Bool = false
    ) {
        self.text = text
        self.style = style
        self.tailCorner = tailCorner
        self.cornerRadius = cornerRadius
        self.agentVerification = agentVerification
        self.size = size
        self.isPlaceholder = isPlaceholder
    }

    var body: some View {
        ZStack {
            backgroundColor
            content
        }
        .compositingGroup()
        .mask(maskShape)
    }

    // MARK: - Background

    /// Verified `.convos` agents render in lava when they're the focused
    /// member — the same accent the avatar already uses, mirrored into the
    /// bubble so the assistant's presence reads at a glance.
    private var backgroundColor: Color {
        switch style {
        case .user:
            return .colorBubble
        case .focusedMember:
            return agentVerification.isConvosAgent
                ? .colorLava
                : .colorBubbleIncoming
        case .otherMember:
            return .colorBubbleIncoming
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let isCompact: Bool = size == .singleLine
        let lineLimit: Int? = isCompact ? 1 : 8
        let alignment: Alignment = isCompact ? .leading : .center
        let textAlignment: TextAlignment = isCompact ? .leading : .center
        let font: Font = isCompact
            ? .system(.body, weight: .medium)
            : .system(.title, weight: .semibold)
        let minScale: CGFloat = isCompact ? 1.0 : 0.4
        let truncation: Text.TruncationMode = isCompact ? .head : .tail
        let horizontalPadding: CGFloat = isCompact
            ? DesignConstants.Spacing.step4x
            : DesignConstants.Spacing.step6x
        let verticalPadding: CGFloat = isCompact
            ? DesignConstants.Spacing.step3x
            : DesignConstants.Spacing.step6x
        let pulseOpacity: Double = isPlaceholder && placeholderPulsed ? 0.5 : 1.0
        Text(text)
            .font(font)
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlignment)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minScale)
            .truncationMode(truncation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .opacity(pulseOpacity)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: text)
            .onAppear {
                guard isPlaceholder else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    placeholderPulsed = true
                }
            }
    }

    private var textColor: Color {
        if isPlaceholder {
            return .colorTextSecondary
        }
        switch style {
        case .user:
            return .colorTextPrimaryInverted
        case .focusedMember:
            return agentVerification.isConvosAgent ? .colorTextPrimaryInverted : .colorTextPrimary
        case .otherMember:
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
