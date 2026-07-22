#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Coarse length class for a message body, used to pick a render strategy that
/// keeps CoreText layout bounded on the main thread. Classification is cheap
/// (character count plus a capped newline scan) and never measures or lays out
/// the text.
public enum MessageLengthClass {
    case short
    case long
    case pathological
}

/// O(1)-ish body classifier. The original hang came from measuring the whole
/// body (`Text` + `.fixedSize` with no `lineLimit`), so this must stay cheap:
/// no CoreText, no `NSAttributedString`, no `boundingRect`. Thresholds are
/// tunable in one place. Exposed (not private) so any caller that builds a
/// `MessageBubble` preview shares the same classification semantics.
public enum MessageBodyClassifier {
    public static let longCharThreshold: Int = 500 // a few paragraphs; human messages rarely exceed this
    public static let pathologicalCharThreshold: Int = 1_500 // long-form; well past a normal chat message
    public static let shortNewlineThreshold: Int = 20 // many short lines, e.g. code snippets or poems
    static let longPreviewLineLimit: Int = 6
    static let pathologicalPreviewLineLimit: Int = 6
    // Short ease so the inline "Read More" expand/collapse reads as a quick
    // reveal, not a slow unfold that the user has to wait through.
    static let readMoreExpandAnimationDuration: Double = 0.18

    public static func classify(_ text: String) -> MessageLengthClass {
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

    /// Subtle 1px outline for the "Read more" pill, matching Figma per side:
    /// incoming (received, left) uses `color/border/subtle`, outgoing (sent,
    /// right) uses `color/border/inverted/subtle`. Both are adaptive, so
    /// light/dark is automatic and the border stays visible in all four
    /// sender x appearance combos. `colorBorderInvertedSubtle` is the
    /// appearance-swapped twin of `colorBorderSubtle` (light #33 / dark #EB),
    /// so it contrasts with the black-in-light / white-in-dark outgoing bubble.
    /// The incoming border uses a dedicated `colorBorderReadMoreIncoming`
    /// rather than the shared `colorBorderSubtle`: in dark mode the latter is
    /// #33, the same as the incoming bubble fill (`colorBubbleIncoming` dark),
    /// so the border vanished. The dedicated token lifts the dark value to #52
    /// (a gentle step lighter than the #33 bubble) while keeping the light
    /// value at #EB, and scopes the change to this border so the 16 other
    /// `colorBorderSubtle` usages are untouched.
    private var readMoreBorderColor: Color {
        if isOutgoing {
            return Color.colorBorderInvertedSubtle
        } else {
            return Color.colorBorderReadMoreIncoming
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
    /// inline "Read More" that lifts the line cap in place. The collapsed
    /// preview is a bounded `Text(lineLimit:)` teaser. Once expanded, a body
    /// that contains a link is rendered through the same scroll-disabled
    /// `LinkDetectingTextView` (UITextView) that short link-bodies use, so URLs
    /// in 500-1500 char messages become tappable. Data detection is async and
    /// a non-scrolling `sizeThatFits` over <=1500 chars is well under a
    /// millisecond, so this does not reintroduce the layout hang.
    @ViewBuilder
    private var longBody: some View {
        let lineCap: Int? = isExpanded ? nil : MessageBodyClassifier.longPreviewLineLimit
        let duration: Double = MessageBodyClassifier.readMoreExpandAnimationDuration
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            longBodyText(lineCap: lineCap)
            if !isExpanded {
                let expandAction: () -> Void = {
                    withAnimation(.easeInOut(duration: duration)) { onToggleExpand?() }
                }
                readMoreButton(action: expandAction, hint: "Expands the message")
            }
        }
    }

    /// Collapsed: a bounded plain `Text` teaser (links in the hidden tail are
    /// not tappable, which is fine for a truncated preview). Expanded: if the
    /// body has a link, switch to `LinkDetectingTextView` so links are
    /// tappable; otherwise keep plain `Text` (cheaper). Selection is gated to
    /// the expanded `Text` path; `.textSelection(.enabled)` and `.disabled`
    /// resolve to different concrete types, so the gate is an `if`, not a
    /// ternary inside the modifier argument.
    @ViewBuilder
    private func longBodyText(lineCap: Int?) -> some View {
        if isExpanded, TextLinkPresence.containsLinks(message) {
            LinkDetectingTextView(
                message,
                linkColor: textColor,
                foregroundColor: textColor,
                font: .preferredFont(forTextStyle: .callout)
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
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
    }

    /// Pathological bodies never render full-size inline and never expand in
    /// place. A bounded preview shows, and "Read More" opens the detail view.
    @ViewBuilder
    private var pathologicalBody: some View {
        // The bounded preview is plain truncated Text, so links in it are not
        // individually tappable here. Tappable links live in the detail view's
        // UITextView, which "Read More" opens.
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(message)
                .font(.callout)
                .foregroundStyle(textColor)
                .lineLimit(MessageBodyClassifier.pathologicalPreviewLineLimit)
            let openDetailAction: () -> Void = { onOpenDetail?(message) }
            readMoreButton(action: openDetailAction, hint: "Opens the full message")
        }
        .contentShape(Rectangle())
    }

    /// Distinct, bordered "Read more" pill (per Quarter's Figma spec). The
    /// message bubble sits under the `.messageGesture(...)` overlay, so the
    /// shared `ReadMoreButton` keeps its gesture-passthrough marker here.
    @ViewBuilder
    private func readMoreButton(action: @escaping () -> Void, hint: String) -> some View {
        ReadMoreButton(
            action: action,
            accessibilityHint: hint,
            borderColor: readMoreBorderColor,
            labelColor: textColor,
            gesturePassthrough: true
        )
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
#endif
