import Foundation

/// Shared destinations for the agent-related rows on `ContactCardView`.
enum AgentLinks {
    // swiftlint:disable:next force_unwrapping
    static let getSkillsURL: URL = URL(string: "https://convos.org/assistants")!
    // swiftlint:disable:next force_unwrapping
    static let learnAboutAssistantsURL: URL = URL(string: "https://learn.convos.org/assistants")!
}
