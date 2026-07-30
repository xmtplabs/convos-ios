#if canImport(UIKit)
import Observation
import SwiftUI

/// Carries the attachments menu between the composer's `+` and the host that
/// draws the card.
///
/// The composer can't draw it itself: the bar lives in a `safeAreaBar`, so an
/// overlay of its own is clipped by the bar's bounds. The host floats the card
/// above the composer from its root overlay instead - the same placement the
/// participation card uses, see `ConversationView`. The composer still owns the
/// pickers each row raises, so it hands its handler over when it opens the menu
/// and the card calls back into it.
@MainActor
@Observable
public final class ComposerAttachmentsMenuCoordinator {
    public private(set) var isPresented: Bool = false
    /// What the composer couldn't offer at the moment the menu opened. The rows
    /// grey rather than vanish, so the list keeps its length.
    public private(set) var disabledActions: Set<ComposerAttachmentAction> = []
    private var onSelect: ((ComposerAttachmentAction) -> Void)?

    public init() {}

    func present(
        disabledActions: Set<ComposerAttachmentAction>,
        onSelect: @escaping (ComposerAttachmentAction) -> Void
    ) {
        self.disabledActions = disabledActions
        self.onSelect = onSelect
        withAnimation(.snappy(duration: 0.2)) {
            isPresented = true
        }
    }

    public func dismiss() {
        guard isPresented else { return }
        onSelect = nil
        withAnimation(.snappy(duration: 0.2)) {
            isPresented = false
        }
    }

    /// Closes the card and runs the pick. The handler is read before the
    /// dismissal clears it.
    public func select(_ action: ComposerAttachmentAction) {
        let handler = onSelect
        dismiss()
        handler?(action)
    }
}

private struct ComposerAttachmentsMenuEnvironmentKey: EnvironmentKey {
    static let defaultValue: ComposerAttachmentsMenuCoordinator?
    = nil
}

public extension EnvironmentValues {
    /// Set by hosts that draw the attachments card. `nil` means nobody is
    /// listening, and the composer's `+` stays inert rather than opening a menu
    /// that would never appear.
    var composerAttachmentsMenu: ComposerAttachmentsMenuCoordinator? {
        get { self[ComposerAttachmentsMenuEnvironmentKey.self] }
        set { self[ComposerAttachmentsMenuEnvironmentKey.self] = newValue }
    }
}
#endif
