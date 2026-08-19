import SwiftUI

/// What the conversation's sheet contains: the selected lane, with its composer
/// floating over it.
///
/// The composer is a sibling *over* the transcript, not a row above it. That is
/// what lets messages pass under the composer, the capsule and the keyboard
/// while scrolling, instead of stopping dead at the composer's top edge. The
/// clearance the transcript keeps at its bottom is handed to it as a content
/// inset - see `onComposerHeightChanged` - because it is a hosted collection
/// view and a SwiftUI safe-area inset does not reach its `contentInset`.
///
/// Nothing here decides how big the sheet is, or draws its surface, corners or
/// grabber, or handles a drag. Those belong to the presentation - see
/// `conversationSheetPresentation` - which is a real `.sheet`.
struct ConversationSheetSurface<TranscriptContent: View, BarContent: View>: View {
    /// Fired with the composer's height, its clearance included: what the
    /// transcript keeps clear at its bottom, and what the keyboard's dismiss
    /// gesture measures from.
    var onComposerHeightChanged: (CGFloat) -> Void = { _ in }
    /// Fired with how much of the screen the sheet occupies, which is how much of
    /// the Home behind it is covered - and so how much clearance the Home's page
    /// needs at its bottom to be scrollable clear of it.
    var onSheetHeightChanged: (CGFloat) -> Void = { _ in }
    @ViewBuilder let transcriptContent: () -> TranscriptContent
    /// The selected lane's composer.
    @ViewBuilder let barContent: () -> BarContent

    /// How much of the screen the keyboard covers.
    ///
    /// Driven from the keyboard's own notifications rather than left to SwiftUI's
    /// automatic avoidance, which is a separate animation engine on a separate
    /// curve - the composer visibly lagged the capsule, which rides UIKit's
    /// keyboard guide. Taking the avoidance off and moving the composer here puts
    /// both on the one signal.
    ///
    /// It also stops the sheet's content being *shrunk* by the keyboard, which is
    /// what cut the newest message off instead of letting the transcript run on
    /// underneath.
    @State private var keyboardOverlap: CGFloat = 0
    /// The sheet's own frame, which the keyboard's reach is measured against.
    @State private var sheetFrame: CGRect = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            transcriptContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            sheetFrame = frame
            onSheetHeightChanged(frame.height)
        }
        // The clearances are measured from the physical bottom edge, which is
        // where the capsule is measured from too. Without this the sheet's own
        // bottom safe area is added on top and everything floats a home
        // indicator's height too high.
        .ignoresSafeArea(.container, edges: .bottom)
        // One notification for both directions, so a keyboard that changes height
        // - a language switch, a predictive bar appearing - moves the composer too
        // rather than only a show and a hide.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            applyKeyboardFrame(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            applyKeyboardOverlap(0, note: note)
        }
        .accessibilityIdentifier("conversation-bottom-sheet")
    }

    private func applyKeyboardFrame(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // How far the keyboard reaches into this sheet - not its height. A
        // dismissed keyboard keeps its full height and parks the frame *below* the
        // screen, so height alone reads the same up or down, and the clearance
        // never changed.
        applyKeyboardOverlap(max(sheetFrame.maxY - frame.minY, 0), note: note)
    }

    private func applyKeyboardOverlap(_ overlap: CGFloat, note: Notification) {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            keyboardOverlap = overlap
        }
    }

    /// Where the composer's bottom sits above the sheet's own bottom edge.
    ///
    /// Only the slack changes with the keyboard: the capsule measures from the
    /// keyboard's *frame*, which begins above the keyboard you can see, so both
    /// shorten by the same amount and the gap between them holds. SwiftUI's own
    /// keyboard avoidance does the lifting.
    private var composerClearance: CGFloat {
        keyboardOverlap > 0
            ? ConversationSheetMetrics.composerKeyboardBottomClearance
            : ConversationSheetMetrics.composerBottomClearance
    }

    private var composer: some View {
        barContent()
            // Clears the capsule, which floats over this sheet in a window of its
            // own and cannot inset it. Stated from the same metrics the capsule is
            // built from, since neither view contains the other - and reduced by
            // the same slack the capsule uses while the keyboard is up, so the two
            // keep their distance.
            .padding(.bottom, composerClearance)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                onComposerHeightChanged(frame.height)
            }
    }
}
