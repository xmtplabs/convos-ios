import ConvosCore
import SwiftUI

/// Debug bootstrap sheet that surfaces the invite slug for the current
/// builder conversation so the human running `convos-cli` can join as the
/// "assistant" while we don't have a real agent endpoint wired.
///
/// Auto-dismisses once a non-self member joins and the focus session has
/// been promoted to focus on them.
struct CLIBootstrapSheet: View {
    @Bindable var viewModel: AssistantBuilderViewModel
    @State private var didCopy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Invite the assistant")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Copy this invite code and paste it into the convos-cli tool to join the conversation as the assistant.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            inviteCodeBlock

            copyButton

            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the assistant to join…")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inviteCodeBlock: some View {
        if let slug = viewModel.invite?.urlSlug, !slug.isEmpty {
            Text(slug)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.colorTextPrimary)
                .padding(DesignConstants.Spacing.step3x)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 12))
                .textSelection(.enabled)
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView().controlSize(.small)
                Text("Generating invite…")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(DesignConstants.Spacing.step3x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 12))
        }
    }

    private var copyButton: some View {
        let label = didCopy ? "Copied" : "Copy invite code"
        let symbol = didCopy ? "checkmark" : "doc.on.doc"
        let copyAction = {
            guard viewModel.copyInviteToPasteboard() else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                didCopy = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    didCopy = false
                }
            }
        }
        return Button(action: copyAction) {
            Label(label, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .convosButtonStyle(.rounded(fullWidth: true))
        .accessibilityIdentifier("copy-invite-code-button")
        .disabled(viewModel.invite?.urlSlug.isEmpty ?? true)
    }
}

#Preview {
    @Previewable @State var presented: Bool = true
    let viewModel = AssistantBuilderViewModel(session: ConvosClient.mock().session)
    VStack {}
        .selfSizingSheet(isPresented: $presented) {
            CLIBootstrapSheet(viewModel: viewModel)
        }
}
