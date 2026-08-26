import ConvosCore
import SwiftUI

struct DocWaitingItemCard: View {
    let item: DocWaitingItem
    let sendState: DocItemSendState?
    let isEnabled: Bool
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void

    @State private var answerText: String = ""

    var body: some View {
        Group {
            if case .resolving = sendState {
                resolvingCard
            } else {
                waitingCard
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16.0)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16.0)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1.0)
        }
        .accessibilityIdentifier("doc-waiting-\(item.id)")
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Circle()
                    .fill(.red)
                    .frame(width: 8.0, height: 8.0)
                    .accessibilityHidden(true)
                Text(kindTitle)
                    .font(.caption2.weight(.semibold).smallCaps())
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(item.chips, id: \.self) { chip in
                            Button(chip) {
                                onAnswer(.choice(chip))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .frame(minHeight: 44.0)
                            .disabled(!isEnabled)
                        }
                    }
                }
            }

            HStack(spacing: DesignConstants.Spacing.step2x) {
                TextField("Type an answer…", text: $answerText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 44.0)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14.0)
                    )
                    .submitLabel(.send)
                    .onSubmit(sendText)

                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30.0))
                        .frame(width: 44.0, height: 44.0)
                }
                .disabled(!isEnabled || cleanAnswer.isEmpty)
                .accessibilityLabel("Send answer")
            }

            if case .failed = sendState {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Label("Couldn't send your answer", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button("Retry", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44.0)
                }
                .accessibilityIdentifier("doc-waiting-retry")
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    private var resolvingCard: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            Text("Answer sent")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(DesignConstants.Spacing.step4x)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var cleanAnswer: String {
        answerText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kindTitle: String {
        switch item.kind {
        case .question:
            return "Question"
        case .unknownContributor:
            return "Unknown contributor"
        case .noticeAsk:
            return "Needs review"
        }
    }

    private func sendText() {
        let text = cleanAnswer
        guard isEnabled, !text.isEmpty else { return }
        answerText = ""
        onAnswer(.text(text))
    }
}
