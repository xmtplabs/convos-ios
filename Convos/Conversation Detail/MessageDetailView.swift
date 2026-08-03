import ConvosCore
import SwiftUI
import UIKit

/// Full-screen sheet for reading a single long message body. Presented from
/// `ConversationView` via `.sheet(item: $viewModel.presentingMessageDetail)`
/// when a pathological message bubble's "Read More" is tapped (mirrors the
/// `ThinkingDetailView` sheet pattern, since the conversation screen has no
/// in-line `NavigationStack` and the messages list is a UIKit collection).
///
/// The body renders in a scroll-enabled `UITextView` (`SelectableTextView`)
/// rather than a SwiftUI `Text`: a whole-body `Text` in the sheet would pay
/// the same synchronous full-height CoreText measure during the present
/// transition that the inline bubble was hanging on. A scroll-enabled
/// `UITextView` lays out lazily by line fragment, gives native selection for
/// free, and detects links.
struct MessageDetailView: View {
    let message: AnyMessage
    let onCopy: (String) -> Void
    let onReply: (AnyMessage) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    private var bodyText: String {
        switch message.content {
        case .text(let text):
            return text
        case .emoji(let text):
            return text
        default:
            return ""
        }
    }

    /// What the text view actually renders. TextKit lays out lazily per
    /// paragraph, so a single multi-hundred-KB paragraph forces a full
    /// synchronous layout that delays the sheet presentation and leaves the
    /// body blank (the render half of the giant-message hang cluster,
    /// CONVOS-IOS-2H/2M/3R). Bodies over the display limit render truncated;
    /// Copy still uses the full `bodyText`.
    private var displayText: String {
        guard bodyText.count > Constant.displayCharacterLimit else { return bodyText }
        return String(bodyText.prefix(Constant.displayCharacterLimit)) + "\n\n[Message truncated for display. Use Copy to get the full text.]"
    }

    var body: some View {
        NavigationStack {
            SelectableTextView(text: displayText, bottomClearance: Constant.bottomContentClearance)
                .ignoresSafeArea(.container, edges: .bottom)
                .safeAreaInset(edge: .bottom) { bottomActionBar }
                .navigationTitle("Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { backToolbarItem }
        }
        .accessibilityIdentifier("message-detail-view")
        .presentationDetents([.large])
    }

    @ToolbarContentBuilder
    private var backToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let backAction: () -> Void = { dismiss() }
            Button(action: backAction) {
                Image(systemName: "chevron.backward")
            }
            .accessibilityIdentifier("message-detail-back-button")
            .accessibilityLabel("Back")
        }
    }

    private var bottomActionBar: some View {
        HStack {
            let copyAction: () -> Void = { onCopy(bodyText) }
            Button(action: copyAction) {
                actionIcon("doc.on.doc")
            }
            .accessibilityIdentifier("message-detail-copy-button")
            .accessibilityLabel("Copy")

            Spacer()

            let replyAction: () -> Void = { onReply(message) }
            Button(action: replyAction) {
                actionIcon("arrowshape.turn.up.left")
            }
            .accessibilityIdentifier("message-detail-reply-button")
            .accessibilityLabel("Reply")
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
    }

    private func actionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .frame(width: Constant.actionButtonSize, height: Constant.actionButtonSize)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private enum Constant {
        static let actionButtonSize: CGFloat = 44.0
        /// Cap on how much of the body the sheet renders. TextKit lays out
        /// a paragraph at a time, so anything beyond roughly this size in a
        /// single paragraph stalls layout for seconds and presents blank.
        static let displayCharacterLimit: Int = 50_000
        /// Bottom content inset for the scrolling body so its last line and
        /// scroll indicator clear the floating Copy/Reply buttons. Covers the
        /// button height, the action bar's bottom padding, and a comfortable
        /// gap. The bottom safe-area inset is added on top automatically by the
        /// text view's `adjustedContentInset` (the bar is placed via
        /// `safeAreaInset`, the body extends under it via `ignoresSafeArea`).
        static let bottomContentClearance: CGFloat = actionButtonSize
            + DesignConstants.Spacing.step3x
            + DesignConstants.Spacing.step4x
    }
}

/// Scroll-enabled, non-editable `UITextView` for the message detail body.
/// Distinct from `LinkDetectingTextView` (which is `isScrollEnabled = false`
/// and self-sizes via `sizeThatFits` - the very full-measure cost this view
/// avoids). Keeping `isScrollEnabled = true` is what makes TextKit lay out
/// incrementally instead of measuring the whole string up front.
private struct SelectableTextView: UIViewRepresentable {
    let text: String
    /// Extra bottom inset so the final line and scroll indicator sit above the
    /// floating Copy/Reply buttons. Applied as `contentInset.bottom` (not
    /// `textContainerInset`) so the scroll indicator is inset too; the bottom
    /// safe area is added on top by `adjustedContentInset`.
    let bottomClearance: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        let inset: CGFloat = DesignConstants.Spacing.step4x
        textView.textContainerInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        // Link detection runs NSDataDetector over the whole string on the
        // main thread while the sheet presents. On pathological bodies
        // (hundreds of KB) that scan delayed the presentation by seconds
        // and left the body blank, so linkify only reasonably-sized text.
        if text.count <= Constant.linkDetectionCharacterLimit {
            textView.dataDetectorTypes = .link
        }
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.contentInset.bottom != bottomClearance {
            uiView.contentInset.bottom = bottomClearance
            uiView.verticalScrollIndicatorInsets.bottom = bottomClearance
        }
    }

    private enum Constant {
        static let linkDetectionCharacterLimit: Int = 50_000
    }
}
