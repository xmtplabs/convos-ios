import ConvosCore
import SwiftUI

/// Coarse length class for a message body, used to pick a render strategy that
/// keeps CoreText layout bounded on the main thread. Classification is cheap
/// (character count plus a capped newline scan) and never measures or lays out
/// the text.
enum MessageLengthClass {
    case short
    case long
    case pathological
}

/// O(1)-ish body classifier. The original hang came from measuring the whole
/// body (`Text` + `.fixedSize` with no `lineLimit`), so this must stay cheap:
/// no CoreText, no `NSAttributedString`, no `boundingRect`. Thresholds are
/// tunable in one place. Exposed (not private) so any caller that builds a
/// `MessageBubble` preview shares the same classification semantics.
enum MessageBodyClassifier {
    static let longCharThreshold: Int = 1_200 // ~3-4 paragraphs at typical density
    static let pathologicalCharThreshold: Int = 6_000 // ~1-2 pages of text
    static let shortNewlineThreshold: Int = 30 // many short lines, e.g. code snippets or poems
    static let longPreviewLineLimit: Int = 12
    static let pathologicalPreviewLineLimit: Int = 8

    static func classify(_ text: String) -> MessageLengthClass {
        let count: Int = text.count
        if count > pathologicalCharThreshold { return .pathological }
        let newlines: Int = newlineCount(in: text, cappedAt: shortNewlineThreshold + 1)
        if count > longCharThreshold || newlines > shortNewlineThreshold { return .long }
        return .short
    }

    /// Counts `\n` but stops as soon as the cap is reached so a newline-spam
    /// body cannot make the scan itself expensive.
    private static func newlineCount(in text: String, cappedAt cap: Int) -> Int {
        var n: Int = 0
        for ch in text where ch == "\n" {
            n += 1
            if n >= cap { break }
        }
        return n
    }
}

struct MessageBubble: View {
    let style: MessageBubbleType
    let message: String
    let isOutgoing: Bool
    let profile: Profile
    /// Invoked when a pathological body's "Read More" is tapped, so the host
    /// can present `MessageDetailView`. `nil` in previews and the context-menu
    /// preview path, where the bounded preview just renders without a tap.
    var onOpenDetail: ((String) -> Void)?
    /// Whether the long-body inline expansion is on. Owned by the conversation
    /// view model (keyed by message id) and passed in, not local `@State`, so
    /// expansion survives `UICollectionView` cell reuse and never bleeds onto
    /// a recycled cell showing a different message.
    var isExpanded: Bool = false
    /// Toggles the long-body inline expansion on the host. `nil` in previews
    /// and the context-menu preview path (the long body just stays collapsed).
    var onToggleExpand: (() -> Void)?

    private var textColor: Color {
        if isOutgoing {
            return Color.colorTextPrimaryInverted
        } else {
            return Color.colorTextPrimary
        }
    }

    private var lengthClass: MessageLengthClass {
        MessageBodyClassifier.classify(message)
    }

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            bubbleContent
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, 10.0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName): \(message)")
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch lengthClass {
        case .short:
            shortBody
        case .long:
            longBody
        case .pathological:
            pathologicalBody
        }
    }

    /// Short bodies are safe to fully measure, so this matches the original
    /// render exactly, including `.fixedSize`. Only messages that contain a
    /// link pay for the TextKit-backed `LinkDetectingTextView`; everything
    /// else is plain `Text`, which is far cheaper to build and measure.
    @ViewBuilder
    private var shortBody: some View {
        if TextLinkPresence.containsLinks(message) {
            LinkDetectingTextView(
                message,
                linkColor: textColor,
                foregroundColor: textColor,
                font: .preferredFont(forTextStyle: .callout)
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(message)
                .font(.callout)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Long (but not pathological) bodies render a bounded preview with an
    /// inline "Read More" that lifts the line cap in place. `.fixedSize` is
    /// dropped (the `lineLimit` is what bounds the vertical layout); selection
    /// is gated to the expanded state so the collapsed measure stays cheap.
    /// Links render as plain `Text` here to avoid the unbounded TextKit
    /// `sizeThatFits`; tappable links live in the detail view.
    @ViewBuilder
    private var longBody: some View {
        let lineCap: Int? = isExpanded ? nil : MessageBodyClassifier.longPreviewLineLimit
        VStack(alignment: .leading, spacing: 4.0) {
            longBodyText(lineCap: lineCap)
            if !isExpanded {
                let expandAction: () -> Void = {
                    withAnimation(.easeInOut(duration: 0.18)) { onToggleExpand?() }
                }
                readMoreButton(action: expandAction, hint: "Double tap to expand the message")
            }
        }
    }

    /// Selection is gated to the expanded state. `.textSelection(.enabled)` and
    /// `.textSelection(.disabled)` resolve to different concrete types, so the
    /// gate is an `if` rather than a ternary inside the modifier argument.
    @ViewBuilder
    private func longBodyText(lineCap: Int?) -> some View {
        let base = Text(message)
            .font(.callout)
            .foregroundStyle(textColor)
            .lineLimit(lineCap)
        if isExpanded {
            base.textSelection(.enabled)
        } else {
            base.textSelection(.disabled)
        }
    }

    /// Pathological bodies never render full-size inline and never expand in
    /// place. A bounded preview shows, and "Read More" opens the detail view.
    @ViewBuilder
    private var pathologicalBody: some View {
        VStack(alignment: .leading, spacing: 4.0) {
            Text(message)
                .font(.callout)
                .foregroundStyle(textColor)
                .lineLimit(MessageBodyClassifier.pathologicalPreviewLineLimit)
            let openDetailAction: () -> Void = { onOpenDetail?(message) }
            readMoreButton(action: openDetailAction, hint: "Double tap to open the full message")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func readMoreButton(action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            Text("Read More")
                .font(.callout.weight(.semibold))
                .foregroundStyle(textColor.opacity(0.75))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        // The bubble is wrapped by `.messageGesture(...)`, whose gesture
        // overlay swallows taps on plain in-bubble controls (its `hitTest`
        // returns the overlay unless the point hits a `LinkHitTestable` view
        // or a passthrough marker). Mark this button so the overlay lets the
        // tap through, mirroring the voice-memo transcript buttons. Hide the
        // marker from accessibility so the representable doesn't surface a
        // second element carrying the button's identifier.
        .background(
            GesturePassthroughBackground()
                .accessibilityHidden(true)
        )
        .accessibilityIdentifier("message-read-more-button")
    }
}

struct EmojiBubble: View {
    let emoji: String
    let isOutgoing: Bool
    let profile: Profile

    private var textColor: Color {
        if isOutgoing {
            return Color.colorTextPrimaryInverted
        } else {
            return Color.colorTextPrimary
        }
    }

    var body: some View {
        MessageContainer(style: .none, isOutgoing: isOutgoing) {
            Text(emoji)
                .foregroundStyle(textColor)
                .font(.largeTitle.pointSize(64.0))
                .padding(.horizontal, 0.0)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName): \(emoji)")
    }
}

#Preview {
    VStack {
        ForEach([MessageSource.outgoing, MessageSource.incoming], id: \.self) { type in
            MessageBubble(
                style: .normal,
                message: "Hello world!",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            MessageBubble(
                style: .normal,
                message: "Check out https://convos.org for more info",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            MessageBubble(
                style: .tailed,
                message: "Visit www.example.com or email us at hello@example.com",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
            EmojiBubble(
                emoji: "❤️❤️❤️",
                isOutgoing: type == .outgoing,
                profile: .mock(),
            )
        }
    }
    .padding(.horizontal, 12.0)
}
