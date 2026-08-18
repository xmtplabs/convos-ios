import ConvosComposer
import SwiftUI

/// Owns the conversation sheet's focus state, from inside the sheet.
///
/// SwiftUI focus is per-presentation: a `@FocusState` declared outside a sheet
/// cannot focus a field within it. Both composers live in the sheet, so their
/// focus has to be declared here rather than in `ConversationView`, which is the
/// presenter. Without this, `FocusCoordinator.moveFocus` still runs and still
/// updates the coordinator, but nothing takes first responder - which is why
/// switching tabs with the keyboard up used to drop it.
///
/// One state per composer, because both transcripts stay mounted and a shared
/// value would have the two fields fighting over it. Each mirrors its own
/// coordinator through `FocusCoordinatorSync`, the same bridge the shell around
/// the sheet uses for its own editors.
struct ConversationSheetFocusHost<Content: View>: View {
    let groupCoordinator: FocusCoordinator
    let agentCoordinator: FocusCoordinator
    /// Re-seeds focus when this changes, e.g. the conversation being shown.
    let resetToken: AnyHashable?
    @ViewBuilder let content: (
        FocusState<MessagesViewInputFocus?>.Binding,
        FocusState<MessagesViewInputFocus?>.Binding
    ) -> Content

    @FocusState private var groupFocus: MessagesViewInputFocus?
    @FocusState private var agentFocus: MessagesViewInputFocus?

    var body: some View {
        content($groupFocus, $agentFocus)
            .focusCoordinatorSync(
                focusState: $groupFocus,
                coordinator: groupCoordinator,
                resetToken: resetToken
            )
            .focusCoordinatorSync(
                focusState: $agentFocus,
                coordinator: agentCoordinator,
                resetToken: resetToken
            )
    }
}
