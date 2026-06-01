import SwiftUI

/// Shown as a confirmation step before starting a conversation that
/// includes an agent - from the contacts picker or the "Chat" button on a
/// agent's contact card. Explains that agents are instance-per-conversation
/// (no shared context) and that whoever adds an agent funds its usage. The
/// "Got it" button confirms and proceeds with creating the conversation;
/// dismissing the sheet any other way cancels.
struct OneAgentManyConvosInfoSheet: View {
    /// Invoked when the user taps "Got it". The host creates the
    /// conversation from its sheet's `onDismiss` so creation runs after this
    /// sheet has fully dismissed.
    var onConfirm: () -> Void = {}

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Agent Contacts",
            title: "One agent,\nmany convos",
            paragraphs: [
                .init("For privacy, agents cannot share memories, context or skills between conversations.", size: .body),
                .init("Whoever adds an agent funds its usage.", size: .subheadline),
            ],
            primaryButtonAction: {
                onConfirm()
                dismiss()
            },
            showDragIndicator: true
        )
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true

    VStack {
        Button { isPresented.toggle() } label: { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        OneAgentManyConvosInfoSheet()
    }
}
