import ConvosCore
import SwiftUI
import UIKit

/// User's own live bubble that doubles as a text field. The keyboard types
/// directly into the bubble — there is no separate composer field below.
///
/// Backed by `HonkTextView` (a `UITextView` wrapper) rather than SwiftUI's
/// `TextField(axis: .vertical)` because the latter sizes itself to its
/// intrinsic content height and won't honor a tall frame's vertical
/// alignment — short text gets pinned near the bottom of the bubble and
/// the placeholder gets clipped.
struct LiveBubbleEditor: View {
    @Binding var text: String
    let placeholder: String
    let tailCorner: BubbleCorner
    let onSubmit: () -> Void
    var isFocusedExternally: Binding<Bool>?
    var size: LiveBubbleSize = .full

    @State private var internalIsFocused: Bool = false

    private let cornerRadius: CGFloat = Constant.bubbleCornerRadius

    var body: some View {
        let isCompact: Bool = size == .singleLine
        ZStack {
            Color.colorBubble
            editor
                .opacity(isCompact ? 0 : 1)
            if isCompact, !text.isEmpty {
                staticDotsOverlay
                    .allowsHitTesting(false)
            }
        }
        .compositingGroup()
        .mask(maskShape)
    }

    private var staticDotsOverlay: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.colorTextPrimaryInverted.opacity(0.7))
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        let isCompact: Bool = size == .singleLine
        let font: UIFont = isCompact
            ? UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
            : UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        let horizontalPadding: CGFloat = isCompact
            ? DesignConstants.Spacing.step4x
            : DesignConstants.Spacing.step6x
        let verticalPadding: CGFloat = isCompact
            ? DesignConstants.Spacing.step3x
            : DesignConstants.Spacing.step6x
        let alignment: NSTextAlignment = isCompact ? .left : .center
        HonkTextView(
            text: $text,
            placeholder: placeholder,
            font: font,
            textColor: UIColor(.colorTextPrimaryInverted),
            placeholderColor: UIColor(.colorTextPrimaryInverted).withAlphaComponent(0.6),
            cursorColor: UIColor(.colorTextPrimaryInverted),
            textAlignment: alignment,
            onSubmit: onSubmit,
            isFocused: focusBinding
        )
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    /// Route HonkTextView's focus binding to either the caller-supplied
    /// `Binding<Bool>` or our internal `@State`. We do not use `@FocusState`
    /// here because there's no SwiftUI `.focused()` consumer for it — the
    /// editor is a `UITextView` via `UIViewRepresentable`, and an unattached
    /// `@FocusState` auto-reverts to `false` on every render, which breaks
    /// our "stay focused" behavior.
    private var focusBinding: Binding<Bool> {
        Binding(
            get: { isFocusedExternally?.wrappedValue ?? internalIsFocused },
            set: { newValue in
                if let isFocusedExternally {
                    isFocusedExternally.wrappedValue = newValue
                } else {
                    internalIsFocused = newValue
                }
            }
        )
    }

    private func focusEditor(_ focused: Bool) {
        if let isFocusedExternally {
            isFocusedExternally.wrappedValue = focused
        } else {
            internalIsFocused = focused
        }
    }

    private var maskShape: UnevenRoundedRectangle {
        let small: CGFloat = 4.0
        let big: CGFloat = cornerRadius
        switch tailCorner {
        case .topLeading:
            return .rect(topLeadingRadius: small, bottomLeadingRadius: big, bottomTrailingRadius: big, topTrailingRadius: big)
        case .topTrailing:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: big, topTrailingRadius: small)
        case .bottomLeading:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: small, bottomTrailingRadius: big, topTrailingRadius: big)
        case .bottomTrailing:
            return .rect(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: small, topTrailingRadius: big)
        }
    }
}

#Preview {
    @Previewable @State var text: String = ""
    LiveBubbleEditor(
        text: $text,
        placeholder: "Type something",
        tailCorner: .bottomTrailing,
        onSubmit: { text = "" }
    )
    .padding()
    .frame(height: 280)
}
