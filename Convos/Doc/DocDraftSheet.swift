import ConvosCore
import SwiftUI

struct DocDraftSheet: View {
    let item: DocWaitingItem
    let startsEdited: Bool
    let isEnabled: Bool
    let onAnswer: (DocAnswer) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @State private var editedText: String

    init(
        item: DocWaitingItem,
        startsEdited: Bool = false,
        isEnabled: Bool,
        onAnswer: @escaping (DocAnswer) -> Void
    ) {
        self.item = item
        self.startsEdited = startsEdited
        self.isEnabled = isEnabled
        self.onAnswer = onAnswer
        let original = item.draft?.text ?? ""
        _editedText = State(
            initialValue: startsEdited ? original + "\n- Dinner: Friday at 7 PM" : original
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                if let anchor = item.draft?.anchor {
                    Label(anchor, systemImage: "text.book.closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                        .frame(minHeight: 28.0)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }

                TextEditor(text: $editedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(DesignConstants.Spacing.step3x)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14.0)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14.0)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1.0)
                    }
                    .accessibilityLabel("Draft text")
                    .accessibilityIdentifier("doc-draft-editor")

                actionButtons
            }
            .padding(DesignConstants.Spacing.step4x)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(item.headline)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("doc-draft-sheet")
    }

    private var cleanText: String {
        editedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                approveButton
                discardButton
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                discardButton
                approveButton
            }
        }
    }

    private var discardButton: some View {
        Button("Discard", role: .destructive) {
            answer(.action(.discard, edited: nil))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled)
    }

    private var approveButton: some View {
        Button("Approve") {
            let edited = editedText == item.draft?.text ? nil : editedText
            answer(.action(.approve, edited: edited))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44.0)
        .disabled(!isEnabled || cleanText.isEmpty)
    }

    private func answer(_ answer: DocAnswer) {
        onAnswer(answer)
        dismiss()
    }
}
