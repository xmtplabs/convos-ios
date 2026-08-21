import ConvosComposer
import ConvosCore
import SwiftUI

/// Every state the agent transcript can be in, as previews, because most of
/// them need a backend, a slow agent or a deadline to reach on a device.
/// Each one composes the real bubbles in the real container, so what shows
/// here is what the screen renders.

private func previewLink(_ host: String, title: String?) -> AgentRelayLink {
    AgentRelayLink(title: title, url: URL(string: "https://\(host)/doc/1") ?? URL(fileURLWithPath: "/"))
}

/// The transcript's own container - same spacing, same padding, same
/// backdrop - so a state seen here is the state the screen renders.
private struct PreviewTranscript<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DesignConstants.Spacing.step3x) {
                content()
            }
            .padding(DesignConstants.Spacing.step4x)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
    }
}

/// Every bubble the transcript can show, in the order a real session meets
/// them: a finished answer with a link, a turn being waited on with its
/// second counter, one past the watch deadline, one the user stopped waiting
/// on, a failure, a request that expired, and a reply collected on another
/// device.
@MainActor
@ViewBuilder
private func previewEveryState() -> some View {
    AgentTranscriptNote(text: AgentSetupCopy.contextBoundary(for: .tasklet))
    AgentUserBubble(text: "Draft the packing list for the Lisbon trip and share the doc.")
    AgentReplyBubble(
        message: "Done. I drafted the list from last year's trip and dropped it in a doc.",
        links: [previewLink("docs.google.com", title: "Lisbon packing list")],
        onOpenLink: { _ in }
    )
    AgentUserBubble(text: "Book the airport transfer too.")
    AgentPendingBubble(
        startedAt: Date().addingTimeInterval(-218),
        deadline: Date().addingTimeInterval(382),
        workingMessage: AgentSetupCopy.workingNote,
        pastDeadlineMessage: AgentSetupCopy.stillWorkingNote,
        onCheckAgain: {},
        onStopWaiting: {}
    )
    AgentPendingBubble(
        startedAt: Date().addingTimeInterval(-742),
        deadline: Date().addingTimeInterval(-142),
        workingMessage: AgentSetupCopy.workingNote,
        pastDeadlineMessage: AgentSetupCopy.stillWorkingNote,
        onCheckAgain: {},
        onStopWaiting: {}
    )
    AgentStatusBubble(
        systemImage: "clock.arrow.circlepath",
        message: AgentSetupCopy.stoppedWaitingNote
    ) {
        AgentBubbleAction(title: "Check again", action: {})
    }
    AgentStatusBubble(
        systemImage: "exclamationmark.triangle.fill",
        message: "Convos is not signed in yet. Try again in a moment.",
        glyphTint: .colorCaution
    ) {
        AgentBubbleAction(title: "Try again", action: {})
    }
    AgentStatusBubble(
        systemImage: "hourglass",
        message: AgentSetupCopy.errorMessage(.expired, provider: .tasklet),
        glyphTint: .colorCaution
    ) {
        AgentBubbleAction(title: "Try again", action: {})
    }
    AgentStatusBubble(
        systemImage: "iphone.gen3",
        message: AgentSetupCopy.collectedElsewhereNote
    ) {
        AgentBubbleAction(title: "Try again", action: {})
    }
}

#Preview("Transcript states") {
    PreviewTranscript { previewEveryState() }
}

#Preview("Transcript states, dark") {
    PreviewTranscript { previewEveryState() }
        .preferredColorScheme(.dark)
}

#Preview("Empty transcript") {
    PreviewTranscript {
        AgentTranscriptEmptyState(provider: .tasklet)
    }
}

#Preview("Empty transcript, dark") {
    PreviewTranscript {
        AgentTranscriptEmptyState(provider: .tasklet)
    }
    .preferredColorScheme(.dark)
}

/// What the transcript looks like straight after a clear made while one turn
/// was still in flight: the turn that is still working, and nothing else.
/// Never the empty state, which would claim nothing had been sent.
#Preview("Cleared, one turn still working") {
    PreviewTranscript {
        AgentTranscriptNote(text: AgentSetupCopy.contextBoundary(for: .tasklet))
        AgentUserBubble(text: "Summarise the thread and send me the decisions.")
        AgentPendingBubble(
            startedAt: Date().addingTimeInterval(-37),
            deadline: Date().addingTimeInterval(563),
            workingMessage: AgentSetupCopy.workingNote,
            pastDeadlineMessage: AgentSetupCopy.stillWorkingNote,
            onCheckAgain: {},
            onStopWaiting: {}
        )
    }
}

#Preview("Clear history confirmation") {
    @Previewable @State var isPresented: Bool = true
    PreviewTranscript {
        AgentUserBubble(text: "Draft the packing list for the Lisbon trip.")
        AgentReplyBubble(
            message: "Done. It is in a doc.",
            links: [previewLink("docs.google.com", title: "Lisbon packing list")],
            onOpenLink: { _ in }
        )
    }
    .agentClearHistoryDialog(
        isPresented: $isPresented,
        providerName: ExternalAgentProvider.tasklet.displayName,
        onClear: {}
    )
}

/// A build that cannot reach a relay at all. The pending bubble says so in
/// place of the working line, rather than counting up towards an answer that
/// is never coming.
#Preview("Preview backend") {
    PreviewTranscript {
        AgentUserBubble(text: "Say hello to confirm the Convos connection.")
        AgentPendingBubble(
            startedAt: Date().addingTimeInterval(-12),
            deadline: Date().addingTimeInterval(588),
            workingMessage: AgentSetupCopy.previewBackendNote,
            pastDeadlineMessage: AgentSetupCopy.previewBackendNote,
            onCheckAgain: {},
            onStopWaiting: {}
        )
    }
}

#Preview("Composer notice") {
    VStack(spacing: DesignConstants.Spacing.step4x) {
        AgentComposerNotice(message: "Convos is not signed in yet. Try again in a moment.", onDismiss: {})
        AgentComposerNotice(
            message: "Town turned down the webhook secret. Copy it again from the routine's webhook settings.",
            onDismiss: {}
        )
    }
    .padding(DesignConstants.Spacing.step4x)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.colorBackgroundSurfaceless)
}

#Preview("Composer notice, dark") {
    VStack(spacing: DesignConstants.Spacing.step4x) {
        AgentComposerNotice(message: "Convos is not signed in yet. Try again in a moment.", onDismiss: {})
        AgentComposerNotice(
            message: "Town turned down the webhook secret. Copy it again from the routine's webhook settings.",
            onDismiss: {}
        )
    }
    .padding(DesignConstants.Spacing.step4x)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.colorBackgroundSurfaceless)
    .preferredColorScheme(.dark)
}
