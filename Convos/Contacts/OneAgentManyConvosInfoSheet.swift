import SwiftUI

/// Shown when the user selects an agent in the contacts picker while
/// starting a conversation. Explains that agents are
/// instance-per-conversation (no shared context) and that whoever adds an
/// agent funds its usage.
struct OneAgentManyConvosInfoSheet: View {
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Agent Contacts",
            title: "One agent,\nmany convos",
            paragraphs: [
                .init("For privacy, agents cannot share memories, context or skills between conversations.", size: .body),
                .init("Whoever adds an agent funds its usage.", size: .subheadline),
            ],
            primaryButtonAction: { dismiss() },
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
