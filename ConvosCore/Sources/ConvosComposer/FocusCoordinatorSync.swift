#if canImport(UIKit)
import SwiftUI

/// Mirrors a `FocusCoordinator` onto one presentation's `@FocusState`, and
/// reports that state's changes back.
///
/// SwiftUI's focus system is per-presentation: a `@FocusState` can only focus
/// fields inside the view hierarchy that declares it, and a sheet is its own
/// hierarchy. The conversation therefore has focusable fields on both sides of
/// a presentation boundary - the composer inside the floating sheet, the
/// conversation-name and display-name editors in the shell around it - and
/// needs a `@FocusState` on each side.
///
/// They cannot be split by case: `.displayName` and `.conversationName` each
/// have fields in both places. Instead both sides mirror the same coordinator
/// through this one modifier, and SwiftUI focuses whichever field actually
/// exists in that presentation. Cross-talk is the coordinator's business: its
/// transition flags already suppress the reports that a presentation makes
/// while it is being driven programmatically (see
/// `FocusCoordinator.syncFocusState`).
public struct FocusCoordinatorSync: ViewModifier {
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let coordinator: FocusCoordinator
    /// Re-seeds focus when this changes, e.g. the conversation being shown.
    let resetToken: AnyHashable?
    /// Focus to take on a reset, when the coordinator's default is not wanted.
    let defaultFocusOverride: MessagesViewInputFocus?

    public init(
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        coordinator: FocusCoordinator,
        resetToken: AnyHashable? = nil,
        defaultFocusOverride: MessagesViewInputFocus? = nil
    ) {
        self._focusState = focusState
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.defaultFocusOverride = defaultFocusOverride
    }

    public func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.currentFocus) { _, newFocus in
                // Always follow the coordinator. Guarding on which fields this
                // presentation owns is not possible - the cases overlap - and
                // assigning a focus whose field is absent here is harmless:
                // SwiftUI simply finds nothing to focus.
                focusState = newFocus
            }
            .onChange(of: coordinator.refocusNonce) { _, _ in
                reassertFocus()
            }
            .onChange(of: focusState) { _, newFocus in
                coordinator.syncFocusState(newFocus)
            }
            .task(id: resetToken) {
                focusState = defaultFocusOverride ?? coordinator.defaultFocus
            }
    }

    /// Re-applies `@FocusState` for a same-value `moveFocus` request (see
    /// `FocusCoordinator.refocusNonce`). When `@FocusState` already equals the
    /// target the real first responder may still be gone, so bounce through nil
    /// on the next runloop tick to force SwiftUI to re-acquire it; otherwise a
    /// plain assignment is enough.
    private func reassertFocus() {
        let target = coordinator.currentFocus
        guard focusState == target else {
            focusState = target
            return
        }
        focusState = nil
        DispatchQueue.main.async {
            focusState = target
        }
    }
}

public extension View {
    /// Mirrors `coordinator` onto this presentation's `@FocusState`. See
    /// `FocusCoordinatorSync`.
    func focusCoordinatorSync(
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        coordinator: FocusCoordinator,
        resetToken: AnyHashable? = nil,
        defaultFocusOverride: MessagesViewInputFocus? = nil
    ) -> some View {
        modifier(
            FocusCoordinatorSync(
                focusState: focusState,
                coordinator: coordinator,
                resetToken: resetToken,
                defaultFocusOverride: defaultFocusOverride
            )
        )
    }
}
#endif
