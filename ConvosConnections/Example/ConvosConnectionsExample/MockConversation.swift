import ConvosConnections
import Foundation

/// A stand-in for an XMTP conversation in the example app. Each mock conversation has a
/// stable id (used as the delivery key) and a display name used in the UI.
///
/// The example ships two mock conversations per connection — this is the minimum needed
/// to demonstrate the package's defining feature: iOS authorization is granted once, but
/// enablement is per-conversation, so a user can allow Health in one conversation and not
/// another without revoking iOS-level access.
struct MockConversation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ConnectionKind
}

enum MockConversationCatalog {
    static let byKind: [ConnectionKind: [MockConversation]] = [
        .health: [
            MockConversation(id: "example:health:fitness", name: "Fitness coach", kind: .health),
            MockConversation(id: "example:health:sleep", name: "Sleep coach", kind: .health),
        ],
        .calendar: [
            MockConversation(id: "example:calendar:personal", name: "Personal planner", kind: .calendar),
            MockConversation(id: "example:calendar:work", name: "Work schedule", kind: .calendar),
        ],
        .location: [
            MockConversation(id: "example:location:journal", name: "Daily journal", kind: .location),
            MockConversation(id: "example:location:commute", name: "Commute tracker", kind: .location),
        ],
        .contacts: [
            MockConversation(id: "example:contacts:rolodex", name: "Relationship agent", kind: .contacts),
            MockConversation(id: "example:contacts:onboarding", name: "New-contact welcomer", kind: .contacts),
        ],
        .photos: [
            MockConversation(id: "example:photos:memories", name: "Memories curator", kind: .photos),
            MockConversation(id: "example:photos:screenshots", name: "Screenshot triage", kind: .photos),
        ],
        .music: [
            MockConversation(id: "example:music:dj", name: "Listening DJ", kind: .music),
            MockConversation(id: "example:music:mood", name: "Mood tracker", kind: .music),
        ],
        .motion: [
            MockConversation(id: "example:motion:coach", name: "Activity coach", kind: .motion),
            MockConversation(id: "example:motion:commute", name: "Commute detector", kind: .motion),
        ],
        .homeKit: [
            MockConversation(id: "example:home:keeper", name: "Home-state keeper", kind: .homeKit),
            MockConversation(id: "example:home:planner", name: "Home-scene planner", kind: .homeKit),
        ],
        .screenTime: [
            MockConversation(id: "example:screentime:focus", name: "Focus coach", kind: .screenTime),
            MockConversation(id: "example:screentime:balance", name: "Balance tracker", kind: .screenTime),
        ],
    ]

    static func conversations(for kind: ConnectionKind) -> [MockConversation] {
        byKind[kind] ?? []
    }
}
