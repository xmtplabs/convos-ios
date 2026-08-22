import SwiftUI
import UIKit

/// Keyboard support for the conversation's empty states.
///
/// The transcript underneath is a UIKit view that owns its own keyboard
/// tracking, so the SwiftUI keyboard safe area never reaches an overlay above
/// it - without this the block stays centred on the whole screen with the
/// keyboard over the bottom of it.
enum EmptyStateKeyboard {
    /// How far to move a screen-centred block so it sits centred in the space
    /// between the top chrome and the keyboard.
    ///
    /// A shift rather than a resize: padding around a `maxHeight: .infinity`
    /// frame resolves against the parent's proposal in ways that moved the
    /// block the wrong way and squeezed its text. At rest the block sits at the
    /// screen's centre, `H / 2`. The space left with the keyboard up runs from
    /// `chromeInset` to `H - keyboardHeight`, whose centre is
    /// `(chromeInset + H - keyboardHeight) / 2`, so the difference is
    /// `(chromeInset - keyboardHeight) / 2` and `H` drops out.
    static func shift(chromeInset: CGFloat, keyboardHeight: CGFloat) -> CGFloat {
        guard keyboardHeight > 0.0 else { return 0.0 }
        return (chromeInset - keyboardHeight) / 2.0
    }
}

private struct KeyboardHeightModifier: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                    return
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    height = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    height = 0.0
                }
            }
    }
}

extension View {
    /// Writes the keyboard's height into `height`, animating with the same
    /// spring `MessageContextMenuOverlay` uses so the two move alike.
    func trackingKeyboardHeight(_ height: Binding<CGFloat>) -> some View {
        modifier(KeyboardHeightModifier(height: height))
    }
}
