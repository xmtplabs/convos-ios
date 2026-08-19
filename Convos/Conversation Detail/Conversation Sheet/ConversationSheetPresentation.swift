import SwiftUI

/// Presents the conversation's transcript as a real presentation sheet, so the
/// system owns every part of the interaction that is expensive to fake: the
/// drag, the grabber, the spring physics, interrupting a resize mid-flight, the
/// handoff between scrolling a transcript and resizing the sheet, and the
/// dismissal itself.
///
/// Two sizes, and a real dismissal. `collapsed` is not a detent - it is the
/// sheet not being presented at all - which is what lets a downward drag take
/// the sheet away rather than parking it on a sliver of chrome. That is the
/// system's own interactive dismissal, and it is the reason there is no drag
/// gesture of ours anywhere in this feature.
///
/// The capsule is deliberately *not* in here. A presentation renders above
/// everything in the presenting view, so a capsule in the conversation would be
/// behind this sheet, and a capsule inside it would be dismissed along with it.
/// It is hosted in an overlay window instead - see `ConversationCapsuleOverlay`.
struct ConversationSheetPresentation<SheetContent: View>: ViewModifier {
    /// Which size the sheet rests at. `collapsed` means no sheet.
    @Binding var detent: ConversationSheetDetent
    @ViewBuilder let sheetContent: () -> SheetContent

    /// Bridges the detent onto the system's selection, which only knows about
    /// the sizes the sheet actually has.
    private var presentationSelection: Binding<PresentationDetent> {
        Binding(
            get: { detent.presentationDetent },
            set: { newValue in
                guard let resolved = ConversationSheetDetent.from(presentationDetent: newValue) else {
                    return
                }
                detent = resolved
            }
        )
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { detent.isPresented },
            // Only ever the system telling us it went away. Raising the sheet is
            // the capsule's job, and it does that by naming a size.
            set: { newValue in
                guard !newValue else { return }
                detent = .collapsed
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: isPresented) {
                sheetContent()
                    .presentationDetents(ConversationSheetDetent.presentationDetents, selection: presentationSelection)
                    // The design token supplies the fill; the corners are left to
                    // the system, which matches them to the device bezel.
                    .presentationBackground(.colorBackgroundRaised)
                    .presentationDragIndicator(.visible)
                    // Up through the largest size, because this is the
                    // conversation's chrome rather than a modal: there is never a
                    // point at which touching the Home behind it should be
                    // swallowed.
                    .presentationBackgroundInteraction(.enabled(upThrough: .large))
                    // Scrolling a transcript scrolls it; dragging from its top
                    // edge, or from the grabber, resizes the sheet.
                    .presentationContentInteraction(.scrolls)
            }
    }
}

extension View {
    /// Presents the conversation's sheet. See `ConversationSheetPresentation`.
    func conversationSheetPresentation<SheetContent: View>(
        detent: Binding<ConversationSheetDetent>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(ConversationSheetPresentation(detent: detent, sheetContent: content))
    }
}
