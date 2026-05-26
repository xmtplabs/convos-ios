import ConvosCore
import Foundation

/// Mock model backing the Agent Builder's Remix mode card carousel.
/// Each `RandomAgent` represents a "pickable" agent the user can remix
/// into a new agent of their own. Eventually these come from a server
/// endpoint; for now they're a static list defined below.
///
/// Renders through the existing `AgentContactCardView` by way of
/// `syntheticProfile(in:)` — the card reads `displayName`,
/// `profileEmoji`, and `agentDescription` off a `Profile`, so we just
/// build one that satisfies those accessors.
struct RandomAgent: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let emoji: String
    let jobSummary: String
    /// Items rendered under "Ideas for stuff" in the carousel's
    /// about section — short headline-style prompts, one per line.
    let ideasForStuff: [String]
    /// Items rendered under "Connections" — display names of the
    /// integrations / data sources this agent wires up. Rendered as
    /// a horizontal flow so they should be short single words /
    /// brand names.
    let connections: [String]
    /// Items rendered under "What I can do" — single-word action
    /// verbs the agent supports. Rendered as a horizontal flow with
    /// a trailing "+" affordance.
    let whatICanDo: [String]

    /// Returns a `Profile` that `AgentContactCardView` can render. The
    /// `conversationId` parameter is folded into the synthetic id so
    /// callers can scope the profile to a particular surface (e.g. the
    /// remix carousel for one draft conversation) without colliding on
    /// `Profile.id` if multiple surfaces render the same `RandomAgent`
    /// at once.
    func syntheticProfile(conversationId: String = "remix-carousel") -> Profile {
        Profile(
            inboxId: "remix-\(id)",
            conversationId: conversationId,
            name: displayName,
            avatar: nil,
            isAgent: true,
            metadata: [
                "emoji": .string(emoji),
                "description": .string(jobSummary),
            ]
        )
    }
}

extension RandomAgent {
    /// Static mock corpus used by the remix carousel until the server
    /// endpoint lands. Keep the list short — one phone-width page per
    /// card — and intentionally varied across personas so the carousel
    /// reads as a "browse" surface rather than a single recommendation.
    static let mocks: [RandomAgent] = [
        RandomAgent(
            id: "gro",
            displayName: "Gro",
            emoji: "🍃",
            jobSummary: "I'm your gardening expert that reminds you when to water and when to seed.",
            ideasForStuff: [
                "Watering reminders",
                "Seasonal planting plan",
                "Garden journal",
            ],
            connections: ["Weather", "Calendar", "Notes"],
            whatICanDo: ["Track", "Remind", "Plan", "Identify", "Log"]
        ),
        RandomAgent(
            id: "buff",
            displayName: "Buff",
            emoji: "💪",
            jobSummary: "I'm your strength trainer. Sync your Health data and I'll keep you on track.",
            ideasForStuff: [
                "Weekly workout plan",
                "Progress charts",
                "Form check-ins",
            ],
            connections: ["Health", "Calendar", "Apple Watch"],
            whatICanDo: ["Plan", "Track", "Remind", "Coach", "Log"]
        ),
        RandomAgent(
            id: "reece",
            displayName: "Reece",
            emoji: "🛒",
            jobSummary: "Send me all your receipts and I'll help you save money and split up expenses.",
            ideasForStuff: [
                "Monthly expense summary",
                "Split-bill calculator",
                "Receipt organizer",
            ],
            connections: ["Photos", "Wallet", "Notes"],
            whatICanDo: ["Scan", "Split", "Track", "Categorize", "Export"]
        ),
    ]
}
