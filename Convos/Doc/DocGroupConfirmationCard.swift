import ConvosCore
import SwiftUI

struct DocGroupConfirmationCard: View {
    let item: DocWaitingItem
    let observedSenders: [String]
    let sendState: DocItemSendState?
    let isEnabled: Bool
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        DocItemCardContainer(itemId: item.id) {
            if case .resolving = sendState {
                DocItemResolvingView(label: "Connecting…")
            } else {
                content
            }
        }
        .accessibilityActions {
            Button(DocGroupConfirmationPresentation.confirmLabel, action: confirm)
            Button(DocGroupConfirmationPresentation.rejectLabel, action: reject)
        }
        .accessibilityIdentifier("doc-group-confirmation")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            DocItemKindLine(
                title: "Connect group",
                systemImage: "bubble.left.and.bubble.right.fill",
                color: .colorLava
            )

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if !observedSenders.isEmpty {
                Label("Observed senders: \(observedSenders.joined(separator: ", ")).", systemImage: "person.2")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(relationshipContext)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            choices

            if case .failed = sendState {
                DocItemRetryView(label: "Couldn't send your choice", onRetry: onRetry)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var choices: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                confirmButton(fullWidth: true)
                rejectButton(fullWidth: true)
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                confirmButton(fullWidth: false)
                rejectButton(fullWidth: false)
            }
        }
    }

    private func confirmButton(fullWidth: Bool) -> some View {
        Button(DocGroupConfirmationPresentation.confirmLabel, action: confirm)
            .convosButtonStyle(.rounded(fullWidth: fullWidth, backgroundColor: .colorLava))
            .frame(minHeight: 44.0)
            .disabled(!actionsAreEnabled)
    }

    private func rejectButton(fullWidth: Bool) -> some View {
        Button(DocGroupConfirmationPresentation.rejectLabel, action: reject)
            .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
            .frame(minHeight: 44.0)
            .disabled(!actionsAreEnabled)
    }

    private var actionsAreEnabled: Bool {
        guard isEnabled else { return false }
        switch sendState {
        case .resolving, .awaitingDelivery:
            return false
        case .failed, nil:
            return true
        }
    }

    private var relationshipContext: String {
        guard !item.context.isEmpty else {
            return "If you connect it, new texts from that group will update this doc."
        }
        return item.context
    }

    private func confirm() {
        guard actionsAreEnabled else { return }
        onAnswer(.choice(DocGroupConfirmationPresentation.legacyConfirmValue))
    }

    private func reject() {
        guard actionsAreEnabled else { return }
        onAnswer(.choice(DocGroupConfirmationPresentation.legacyRejectValue))
    }
}
