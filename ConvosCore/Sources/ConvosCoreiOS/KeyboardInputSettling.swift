#if canImport(UIKit)
import ConvosLogging
import UIKit

/// UIKit-level helpers for settling pending keyboard input before
/// programmatically mutating a focused field's bound text.
///
/// This lives in ConvosCoreiOS rather than the app target because the first
/// member lookup through the `UIResponder & UITextInput` existential in the
/// app module is expensive enough to trip the app target's type-check time
/// limit (the app's import graph makes the lazy ObjC member-table load take
/// 600ms+). Keep direct member access on that existential out of the app
/// target; route it through helpers here instead.
public enum KeyboardInputSettling {
    /// Runs `work` with the current first responder's pending input settled,
    /// so that `work` can safely mutate the focused field's bound text
    /// programmatically.
    ///
    /// Two settle strategies:
    /// - `endingInputSession == false` (plain typing): re-assert the
    ///   selection at the UIKit level. A selection change runs the same
    ///   settle path the keyboard uses when the caret moves, with no first
    ///   responder change, so the keyboard never hides or re-shows.
    /// - `endingInputSession == true` (caller believes dictation is active):
    ///   the selection nudge does not stop a dictation session - it keeps
    ///   streaming hypothesis updates into the field after the mutation -
    ///   so the input session has to end first. Resigning first responder
    ///   does that but leaves a no-responder gap that visibly hides and
    ///   re-shows the keyboard, so instead first responder is handed to a
    ///   zero-frame off-screen text field in the same window: a text input
    ///   stays focused throughout, the keyboard never moves, and the
    ///   composer's input session is torn down exactly as on resign. Focus
    ///   returns to the original field after the mutation.
    @MainActor
    public static func withSettledInput(endingInputSession: Bool, _ work: () -> Void) {
        guard let input = currentFirstResponder() as? (UIResponder & UITextInput) else {
            work()
            return
        }
        if endingInputSession {
            endInputSessionKeepingKeyboard(for: input, work)
        } else {
            Log.info("Settling keyboard input via selection nudge")
            let end = input.endOfDocument
            input.selectedTextRange = input.textRange(from: end, to: end)
            work()
        }
    }

    /// Ends `input`'s input session (terminating any active dictation and
    /// committing pending input) without letting the keyboard hide, by
    /// handing first responder to a temporary off-screen text field while
    /// `work` runs. Falls back to a plain resign/restore round-trip when the
    /// input has no window or the handoff field refuses focus.
    @MainActor
    private static func endInputSessionKeepingKeyboard(for input: UIResponder & UITextInput, _ work: () -> Void) {
        guard let inputView = input as? UIView, let window = inputView.window else {
            Log.info("Settling keyboard input via resign/restore (no window for handoff)")
            input.resignFirstResponder()
            work()
            input.becomeFirstResponder()
            return
        }
        // The handoff field deliberately keeps default input traits. The
        // composer uses a default keyboard, so a default handoff field
        // takes focus with no keyboard relayout (frame analysis shows no
        // keyboard movement beyond the keycap shift-case recompute that
        // every composer-clearing send produces, handoff or not). Revisit
        // if a field with a non-default keyboard ever uses this settle
        // path.
        let handoff = UITextField(frame: .zero)
        handoff.isAccessibilityElement = false
        handoff.accessibilityElementsHidden = true
        window.addSubview(handoff)
        defer { handoff.removeFromSuperview() }
        guard handoff.becomeFirstResponder() else {
            Log.info("Settling keyboard input via resign/restore (handoff refused focus)")
            input.resignFirstResponder()
            work()
            input.becomeFirstResponder()
            return
        }
        Log.info("Settling keyboard input via focus handoff (ending input session)")
        work()
        if !input.becomeFirstResponder() {
            Log.error("Focus handoff could not restore the original input; keyboard may dismiss")
        }
    }

    @MainActor
    private static func currentFirstResponder() -> UIResponder? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let responder = window.firstResponderDescendant() {
                    return responder
                }
            }
        }
        return nil
    }
}

private extension UIView {
    func firstResponderDescendant() -> UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.firstResponderDescendant() {
                return responder
            }
        }
        return nil
    }
}
#endif
