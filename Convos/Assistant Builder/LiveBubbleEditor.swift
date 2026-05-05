import ConvosCore
import SwiftUI

/// User's own live bubble that doubles as a text field. The keyboard types
/// directly into the bubble — there is no separate composer field below.
struct LiveBubbleEditor: View {
    @Binding var text: String
    let placeholder: String
    let tailCorner: BubbleCorner
    let onSubmit: () -> Void
    var isFocusedExternally: FocusState<Bool>.Binding?

    @FocusState private var isInternallyFocused: Bool

    private let cornerRadius: CGFloat = Constant.bubbleCornerRadius

    var body: some View {
        ZStack {
            Color.colorBubble
            editor
        }
        .compositingGroup()
        .mask(maskShape)
        .onTapGesture { focusEditor(true) }
    }

    @ViewBuilder
    private var editor: some View {
        let editorView = TextField(
            "",
            text: $text,
            prompt: Text(placeholder)
                .foregroundStyle(Color.colorTextPrimaryInverted.opacity(0.6)),
            axis: .vertical
        )
        .font(.system(.title, weight: .semibold))
        .foregroundStyle(.colorTextPrimaryInverted)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .submitLabel(.return)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step6x)
        .onSubmit(onSubmit)
        .tint(.colorTextPrimaryInverted)

        if let isFocusedExternally {
            editorView.focused(isFocusedExternally)
        } else {
            editorView.focused($isInternallyFocused)
        }
    }

    private func focusEditor(_ focused: Bool) {
        if let isFocusedExternally {
            isFocusedExternally.wrappedValue = focused
        } else {
            isInternallyFocused = focused
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
