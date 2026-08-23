import SwiftUI

/// The offer shown on a conversation with no agent: a button to add one, and a
/// line saying what it is for (Figma 7488:14502).
///
/// Shared by the Agent tab and the Context tab so the two cannot drift. Neither
/// a background nor the chrome's clearance belongs here - the Agent tab centres
/// this on its own dark surface and the Context tab on the conversation's
/// ambient wash, so each host supplies its own.
struct AddAgentPromptView: View {
    /// Asks the conversation's session to provision an agent.
    let onAddAgent: () -> Void
    /// Distinguishes the two hosts' buttons for QA; the label is identical.
    var accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Button(action: onAddAgent) {
                Text("Add an agent")
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(height: Constant.buttonHeight)
                    .background(.colorLava, in: .rect(cornerRadius: Constant.buttonRadius))
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            Text("To help the group out")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorLava)
        }
    }

    private enum Constant {
        static let buttonHeight: CGFloat = 36.0
        static let buttonRadius: CGFloat = 24.0
    }
}

#Preview {
    AddAgentPromptView(onAddAgent: {}, accessibilityIdentifier: "preview-add-agent")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
}
