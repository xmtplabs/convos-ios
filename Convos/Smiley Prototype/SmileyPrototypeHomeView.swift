import ConvosCore
import SwiftUI

/// Throwaway shared-prototype view -- see `prototype.yml`. Prototype home
/// screen (see `FeatureFlags.isSmileyPrototypeEnabled`): the entire app
/// surface is a single giant smiley button. Tapping it builds and joins a
/// fresh agent whose only instruction is to reply with smiley face emoji,
/// reusing the same direct-build pipeline the real "Make an agent" composer
/// uses (`AgentBuilderViewModel.commit`), then morphs into the standard
/// `ConversationView` once the draft group is ready -- identical to the
/// normal builder flow, just pre-seeded and auto-committed instead of
/// waiting on typed input.
struct SmileyPrototypeHomeView: View {
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions

    @State private var builderViewModel: AgentBuilderViewModel?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    var body: some View {
        let tapAction: () -> Void = { startSmileyConversation() }
        let exitAction: () -> Void = { FeatureFlags.shared.isSmileyPrototypeEnabled = false }
        ZStack(alignment: .topTrailing) {
            Color.colorBackgroundSurfaceless.ignoresSafeArea()

            Button(action: tapAction) {
                Text("😀")
                    .font(.system(size: 220))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a conversation with the smiley agent")
            .accessibilityIdentifier("smiley-prototype-home-button")

            // Escape hatch: without this the prototype has no navigation path
            // back to Debug settings (this screen replaces the entire tab
            // shell, including the App Settings sheet that hosts the toggle),
            // so a tester could only exit by clearing UserDefaults. Flagged in
            // review -- flip the flag directly instead of requiring that.
            Button(action: exitAction) {
                Text("Exit prototype")
                    .font(.footnote)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
            }
            .buttonStyle(.bordered)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.trailing, DesignConstants.Spacing.step3x)
            .accessibilityIdentifier("smiley-prototype-exit-button")
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
        let viewModel: AgentBuilderViewModel = AgentBuilderViewModel(session: session, coreActions: coreActions)
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
