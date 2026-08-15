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
    /// Measured chrome height, which the `collapsed` and `compact` detents
    /// resolve against.
    var chromeHeight: CGFloat
    /// Measured height of the transcript's last message, which is what the
    /// `compact` detent sizes itself to.
    var lastMessageHeight: CGFloat
    @ViewBuilder let sheetContent: () -> SheetContent

    @State private var isPresented: Bool = false

    /// The system's detent selection, bridged onto the conversation's own
    /// vocabulary. Reading maps back from whatever the system settled on.
    private var presentationSelection: Binding<PresentationDetent> {
        Binding(
            get: {
                detent.presentationDetent(
                    chromeHeight: chromeHeight,
                    lastMessageHeight: lastMessageHeight
                )
            },
            set: { newValue in
                detent = ConversationSheetDetent.from(
                    presentationDetent: newValue,
                    chromeHeight: chromeHeight,
                    lastMessageHeight: lastMessageHeight
                )
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isPresented = true }
            .sheet(isPresented: $isPresented) {
                sheetContent()
                    .presentationDetents(
                        ConversationSheetDetent.presentationDetents(
                            chromeHeight: chromeHeight,
                            lastMessageHeight: lastMessageHeight
                        ),
                        selection: presentationSelection
                    )
                    // The design token supplies the fill; the corners are left
                    // to the system, which matches them to the device bezel.
                    // Setting presentationCornerRadius overrides that with one
                    // flat radius on all four corners.
                    .presentationBackground(.colorBackgroundRaised)
                    .presentationDragIndicator(.visible)
                    // The Home stays live while the sheet leaves it visible.
                    // Above half the sheet has covered it anyway.
                    .presentationBackgroundInteraction(
                        .enabled(upThrough: ConversationSheetDetent.backgroundInteractionCeiling)
                    )
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
        chromeHeight: CGFloat,
        lastMessageHeight: CGFloat,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(
            ConversationSheetPresentation(
                detent: detent,
                chromeHeight: chromeHeight,
                lastMessageHeight: lastMessageHeight,
                sheetContent: content
            )
        )
    }
}
