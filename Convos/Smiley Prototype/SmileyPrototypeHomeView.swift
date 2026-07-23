import ConvosCore
import SwiftUI

/// Prototype home screen (see `FeatureFlags.isSmileyPrototypeEnabled`): the
/// entire app surface is a single giant smiley button. Tapping it builds and
/// joins a fresh agent whose only instruction is to reply with smiley face
/// emoji, reusing the same direct-build pipeline the real "Make an agent"
/// composer uses (`AgentBuilderViewModel.commit`), then morphs into the
/// standard `ConversationView` once the draft group is ready -- identical to
/// the normal builder flow, just pre-seeded and auto-committed instead of
/// waiting on typed input.
struct SmileyPrototypeHomeView: View {
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions

    @State private var builderViewModel: AgentBuilderViewModel?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    var body: some View {
        ZStack {
            Color.colorBackgroundSurfaceless.ignoresSafeArea()

            Button(action: startSmileyConversation) {
                Text("😀")
                    .font(.system(size: 220))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a conversation with the smiley agent")
            .accessibilityIdentifier("smiley-prototype-home-button")
        }
        .sheet(item: $builderViewModel) { viewModel in
            AgentBuilderView(viewModel: viewModel, profileSettingsViewModel: .shared)
                .background(.colorBackgroundSurfaceless)
                .presentationSizing(.page)
                .interactiveDismissDisabled(true)
        }
    }

    /// Builds a fresh `AgentBuilderViewModel`, seeds its composer with the
    /// smiley-only instruction, and immediately commits -- mirroring what
    /// tapping "Make" in the real composer does, minus the user having to
    /// type anything. `commit()` itself defers the actual generation start
    /// until the inner conversation has an invite slug, so it is safe to
    /// call right away; the short sleep just lets the sheet finish mounting
    /// before the reveal animation kicks off.
    private func startSmileyConversation() {
        let viewModel = AgentBuilderViewModel(session: session, coreActions: coreActions)
        viewModel.composerText = Constant.smileyPrompt
        builderViewModel = viewModel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            viewModel.commit(focusCoordinator: focusCoordinator)
        }
    }

    private enum Constant {
        static let smileyPrompt: String =
            "You only ever reply with one or more smiley face emoji (😀 🙂 😄 😆 😊 😁). " +
            "Never send plain text, words, or any other emoji -- every message you send must " +
            "be smiley faces only, no matter what the other person says."
    }
}
