import SwiftUI

/// Presents the conversation's transcript sheet as a real presentation sheet,
/// so the system owns every part of the interaction that is expensive to fake:
/// the drag, the grabber, the spring physics, interrupting an in-flight resize,
/// handing off between scrolling the transcript and resizing the sheet, and
/// keeping the Home behind it touchable.
///
/// The sheet is never dismissed - it is the conversation's chrome, not a modal
/// - so it presents on appear and dismissal is disabled.
///
/// One consequence worth knowing: a permanently-presented sheet occupies the
/// host's presentation slot, so anything else the conversation shows (a contact
/// card, the reactions drawer, a settings sheet) has to be presented from
/// *inside* this sheet's content rather than from the view that presents it.
struct ConversationSheetPresentation<SheetContent: View>: ViewModifier {
    /// Which detent the sheet rests at. Two-way: the host seeds it per
    /// conversation and the system writes back after a drag.
    @Binding var detent: ConversationSheetDetent
    /// The height the sheet rests at, measured above the bottom safe area,
    /// which the `collapsed` and `compact` detents resolve against.
    /// Every height the sizes resolve against. Sizes above the transcript's own
    /// height are withheld, so the sheet cannot be dragged open onto empty space.
    var heights: ConversationSheetHeights
    /// While a programmatic move is in flight, the only size offered. See
    /// `ConversationView.moveSheet`.
    var forcedDetent: ConversationSheetDetent?
    @ViewBuilder let sheetContent: () -> SheetContent

    @State private var isPresented: Bool = false

    /// The system's detent selection, bridged onto the conversation's own
    /// vocabulary. Reading maps back from whatever the system settled on.
    private var presentationSelection: Binding<PresentationDetent> {
        Binding(
            get: {
                detent.presentationDetent(heights: heights)
            },
            set: { newValue in
                // Only when these measurements describe it. A detent in flight can
                // outlive the heights that produced it, and writing a guess back
                // here is an instruction to the sheet, not a reading of it - see
                // `ConversationSheetDetent.from`.
                guard let resolved = ConversationSheetDetent.from(
                    presentationDetent: newValue,
                    heights: heights
                ) else { return }
                detent = resolved
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isPresented = true }
            // Dismissed as the pop begins, so it slides down with the screen it
            // belongs to. A sheet is a presentation over the whole window, so it
            // does not travel with a navigation transition: left alone it sits
            // there while the conversation slides away, then blinks out when the
            // screen is finally torn down. `onDisappear` is too late to animate
            // from - see `ScreenExitReporter`.
            .background {
                ScreenExitReporter { isPresented = false }
                    .frame(width: 0, height: 0)
            }
            .sheet(isPresented: $isPresented) {
                sheetContent()
                    .presentationDetents(
                        ConversationSheetDetent.presentationDetents(
                            heights: heights,
                            forcing: forcedDetent
                        ),
                        selection: presentationSelection
                    )
                    // The design token supplies the fill; the corners are left
                    // to the system, which matches them to the device bezel.
                    // Setting presentationCornerRadius overrides that with one
                    // flat radius on all four corners.
                    .presentationBackground(.colorBackgroundRaised)
                    .presentationDragIndicator(.visible)
                    // At every size, not up through one of them. This is the
                    // conversation's chrome, not a modal: there is never a point
                    // at which touching the screen behind it should be swallowed
                    // by a dimming view - and where the sheet has covered the Home
                    // there is nothing back there to touch anyway.
                    //
                    // `upThrough:` also cannot work here now that the sizes on
                    // offer depend on how much transcript there is. It names a
                    // detent, and a detent the sheet is not currently offering is
                    // one the system cannot compare against: on a short
                    // conversation, which withholds `compact`, the pass-through
                    // switched off entirely and the dimmer ate every tap - the
                    // Home went grey and even the back button stopped answering.
                    .presentationBackgroundInteraction(.enabled)
                    // Scrolling the transcript scrolls it; dragging from its
                    // top edge, or anywhere in the chrome, resizes the sheet.
                    .presentationContentInteraction(.scrolls)
                    // It is the conversation's chrome. There is nothing behind
                    // it to dismiss back to.
                    .interactiveDismissDisabled()
            }
    }
}

extension View {
    /// Presents the conversation's sheet. See
    /// `ConversationSheetPresentation`.
    func conversationSheetPresentation<SheetContent: View>(
        detent: Binding<ConversationSheetDetent>,
        heights: ConversationSheetHeights,
        forcedDetent: ConversationSheetDetent? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(
            ConversationSheetPresentation(
                detent: detent,
                heights: heights,
                forcedDetent: forcedDetent,
                sheetContent: content
            )
        )
    }
}
