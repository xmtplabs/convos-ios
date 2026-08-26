import ConvosCore
import MessageUI
import SwiftUI
import UIKit

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

struct DocVerifyNumberItemCard: View {
    let item: DocWaitingItem

    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @State private var isComposerPresented: Bool = false
    @State private var isWaitingForText: Bool = false
    @State private var didCopyCode: Bool = false

    var body: some View {
        DocItemCardContainer(itemId: item.id) {
            content
        }
        .sheet(isPresented: $isComposerPresented) {
            messageComposerSheet
        }
        .accessibilityIdentifier("doc-verify-number-\(item.id)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("I go by @doc · \(verificationLineNumber)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            } icon: {
                Image(systemName: "message.fill")
                    .foregroundStyle(.colorLava)
            }
            .accessibilityLabel("Text @doc at \(verificationLineNumber)")

            if let code = item.code {
                codeRow(code)
            }

            if isWaitingForText {
                Label("Waiting for your text…", systemImage: "ellipsis.message")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .transition(.opacity)
            }

            Button("Text @doc to verify") {
                beginVerification()
            }
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
            .frame(minHeight: 44.0)
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var messageComposerSheet: some View {
        if let lineNumber = item.lineNumber, let smsBody = item.smsBody {
            DocMessageComposeView(recipient: lineNumber, body: smsBody) {
                isComposerPresented = false
                withAnimation(.easeOut(duration: 0.16)) {
                    isWaitingForText = true
                }
            }
        }
    }

    @ViewBuilder
    private func codeRow(_ code: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                codeText(code)
                copyCodeButton(code)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .background(
                Color.colorFillMinimal,
                in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
            )
        } else {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                codeText(code)
                Spacer(minLength: 0)
                copyCodeButton(code)
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .background(
                Color.colorFillMinimal,
                in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
            )
        }
    }

    private func codeText(_ code: String) -> some View {
        Text(code)
            .font(.title3.weight(.semibold).monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .textSelection(.enabled)
            .accessibilityLabel("Verification code \(code)")
    }

    private func copyCodeButton(_ code: String) -> some View {
        Button {
            UIPasteboard.general.string = code
            didCopyCode = true
        } label: {
            Label(copyButtonTitle, systemImage: copyButtonImage)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(minHeight: 44.0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.colorLava)
        .accessibilityHint("Copies the verification code for manual sending")
    }

    private var verificationLineNumber: String {
        item.lineNumber ?? ""
    }

    private var copyButtonTitle: String {
        didCopyCode ? "Copied" : "Copy"
    }

    private var copyButtonImage: String {
        didCopyCode ? "checkmark" : "doc.on.doc"
    }

    private func beginVerification() {
        guard let lineNumber = item.lineNumber, let smsBody = item.smsBody else { return }
        if MFMessageComposeViewController.canSendText() {
            isComposerPresented = true
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                isWaitingForText = true
            }
            guard let url = smsURL(lineNumber: lineNumber, body: smsBody) else { return }
            openURL(url)
        }
    }

    private func smsURL(lineNumber: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        guard let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "sms:\(lineNumber)&body=\(encodedBody)")
    }
}

private struct DocMessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = [recipient]
        controller.body = body
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onDismiss()
        }
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
