import ConvosCore
import SwiftUI

struct DocDraftItemCard: View {
    let item: DocWaitingItem
    let sendState: DocItemSendState?
    let isEnabled: Bool
    let onOpen: () -> Void
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void

    var body: some View {
        DocItemCardContainer(itemId: item.id) {
            if case .resolving = sendState {
                DocItemResolvingView(label: "Draft handled")
            } else {
                content
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard actionsAreEnabled else { return }
            onOpen()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Review draft") {
            guard actionsAreEnabled else { return }
            onOpen()
        }
        .accessibilityAction(named: "Approve draft") {
            guard actionsAreEnabled else { return }
            onAnswer(.action(.approve, edited: nil))
        }
        .accessibilityAction(named: "Edit draft") {
            guard actionsAreEnabled else { return }
            onOpen()
        }
        .accessibilityAction(named: "Discard draft") {
            guard actionsAreEnabled else { return }
            onAnswer(.action(.discard, edited: nil))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onAnswer(.action(.approve, edited: nil))
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .tint(.green)
            .disabled(!actionsAreEnabled)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onAnswer(.action(.discard, edited: nil))
            } label: {
                Label("Discard", systemImage: "trash")
            }
            .disabled(!actionsAreEnabled)
        }
        .accessibilityIdentifier("doc-draft-" + item.id)
    }

    private var actionsAreEnabled: Bool {
        isEnabled && sendState == nil
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            DocItemKindLine(
                title: "Draft · " + kindTitle,
                systemImage: "checkmark.circle",
                color: .secondary
            )

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("Review draft", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44.0)

            if case .failed = sendState {
                DocItemRetryView(label: "Couldn't send your choice", onRetry: onRetry)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    private var kindTitle: String {
        switch item.kind {
        case .structure:
            "Structure"
        case .cleanup:
            "Cleanup"
        case .gapFill:
            "Gap fill"
        case .reshare:
            "Reshare"
        default:
            "Review"
        }
    }
}
