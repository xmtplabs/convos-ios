import Foundation

/// Time-box for the optimistic "verified Convos agent is joining" placeholder
/// the chat header shows after an Agent Builder commit.
///
/// While a builder draft is committing, the UI paints the Convos-verified
/// identity (avatar + "Agent" name + "Joining..." subtitle) as a stand-in
/// before the real agent member actually arrives -- see
/// `ConversationViewModel.shouldRenderAsPendingAgent`. If the agent never
/// verifies (e.g. it joins without publishing attestation), that placeholder
/// must not linger forever and mislead the user into reading an unverified
/// agent as a verified Convos one. So it expires `displayDuration` after the
/// commit (`AgentBuilderSummary.cutoffDate`), after which the conversation
/// renders with its real, unverified identity.
///
/// Anchoring on `cutoffDate` (the Make moment) rather than a wall-clock timer
/// start means the window is correct across app relaunches: a summary
/// rehydrated long after its commit is already expired and never shows the
/// placeholder.
public enum AgentBuilderPlaceholder {
    /// How long past the commit the optimistic verified placeholder may show
    /// before falling back to the real (unverified) rendering. Generous enough
    /// to cover a healthy provision -> join -> attestation-publish round trip;
    /// a genuinely verified agent flips the rendering the moment it joins
    /// regardless of this window, so this only bounds the broken case.
    public static let displayDuration: TimeInterval = 60

    /// Seconds remaining before the placeholder should stop showing, measured
    /// from the commit moment. A value <= 0 means the window has already
    /// elapsed and the placeholder should no longer show.
    public static func remainingDisplayTime(since cutoffDate: Date, now: Date = Date()) -> TimeInterval {
        displayDuration - now.timeIntervalSince(cutoffDate)
    }
}
