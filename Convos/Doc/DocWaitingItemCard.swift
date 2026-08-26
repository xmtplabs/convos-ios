import ConvosCore
import SwiftUI

enum DocMotion {
    static func arrival(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.32)
    }

    static func collapse(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(duration: 0.34, bounce: 0.12)
    }

    static func itemTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .opacity.combined(with: .offset(y: -8.0))
    }

    static func docArrival(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .opacity.combined(with: .offset(y: -10.0))
    }
}

struct DocWaitingItemCard: View {
    let item: DocWaitingItem
    let sendState: DocItemSendState?
    let isEnabled: Bool
    @Binding var activeAnswerItemId: String?
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void

    @State private var answerText: String = ""

    var body: some View {
        DocItemCardContainer(itemId: item.id) {
            if case .resolving = sendState {
                DocItemResolvingView(label: "Answer sent")
            } else {
                content
            }
        }
        .accessibilityActions {
            ForEach(item.chips, id: \.self) { chip in
                Button("Answer \(chip)") {
                    guard actionsAreEnabled else { return }
                    onAnswer(.choice(chip))
                }
            }
            Button("Write answer") {
                guard actionsAreEnabled else { return }
                activeAnswerItemId = item.id
            }
        }
        .accessibilityIdentifier("doc-waiting-\(item.id)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            DocItemKindLine(title: kindTitle, systemImage: "circle.fill", color: .red)

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.chips.isEmpty {
                DocAnswerChips(chips: item.chips, isEnabled: actionsAreEnabled) {
                    onAnswer(.choice($0))
                }
            }

            DocInlineAnswerField(
                itemId: item.id,
                compactLabel: "Answer…",
                placeholder: "Type an answer…",
                text: $answerText,
                activeItemId: $activeAnswerItemId,
                isEnabled: actionsAreEnabled
            ) {
                onAnswer(.text($0))
            }

            if case .failed = sendState {
                DocItemRetryView(label: "Couldn't send your answer", onRetry: onRetry)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    private var actionsAreEnabled: Bool {
        isEnabled && sendState == nil
    }

    private var kindTitle: String {
        switch item.kind {
        case .question:
            "Question"
        case .unknownContributor:
            "Unknown contributor"
        case .noticeAsk:
            "Needs review"
        default:
            "Waiting"
        }
    }
}

struct DocInlineAnswerField: View {
    let itemId: String
    let compactLabel: String
    let placeholder: String
    @Binding var text: String
    @Binding var activeItemId: String?
    let isEnabled: Bool
    let onSend: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        if activeItemId == itemId {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 44.0)
                    .background(
                        Color.colorFillMinimal,
                        in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    )
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30.0))
                        .frame(width: 44.0, height: 44.0)
                }
                .disabled(!isEnabled || cleanText.isEmpty)
                .accessibilityLabel("Send answer")
            }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused, activeItemId == itemId {
                    activeItemId = nil
                }
            }
        } else {
            Button {
                activeItemId = itemId
            } label: {
                Label(compactLabel, systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44.0)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.colorLava)
            .disabled(!isEnabled)
        }
    }

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let answer = cleanText
        guard isEnabled, !answer.isEmpty else { return }
        text = ""
        activeItemId = nil
        onSend(answer)
    }
}

struct DocAnswerChips: View {
    let chips: [String]
    let isEnabled: Bool
    let onAnswer: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ForEach(chips, id: \.self) { chip in
                    Button(chip) { onAnswer(chip) }
                        .convosButtonStyle(.outlineCapsule(fullWidth: false))
                        .frame(minHeight: 44.0)
                        .disabled(!isEnabled)
                }
            }
        }
    }
}

struct DocItemKindLine: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold).smallCaps())
            .foregroundStyle(color)
            .tracking(0.5)
    }
}

struct DocItemCardContainer<Content: View>: View {
    let itemId: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                Color.colorBackgroundRaisedSecondary,
                in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("doc-item-\(itemId)")
    }
}

struct DocItemResolvingView: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.colorLava)
                .font(.title3)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(DesignConstants.Spacing.step4x)
        .transition(DocMotion.itemTransition(reduceMotion: reduceMotion))
    }
}

struct DocItemRetryView: View {
    let label: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Label(label, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44.0)
        }
        .accessibilityIdentifier("doc-item-retry")
    }
}
