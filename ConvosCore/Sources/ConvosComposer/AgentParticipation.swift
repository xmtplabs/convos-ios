#if canImport(UIKit)
import SwiftUI

// MARK: - Agent participation

/// How much the agents in a conversation talk. Members pick a level; the agents
/// keep *working* at every level short of Pause — only how much they *speak*
/// changes.
///
/// The level belongs to the conversation, not to one agent: a room holding
/// several agents has a single setting that governs all of them, and an agent
/// that joins later inherits it.
public enum AgentParticipationLevel: String, CaseIterable, Identifiable, Sendable {
    case speakFreely
    case mentionsOnly
    case paused

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speakFreely: "Speak freely"
        case .mentionsOnly: "Listen mode"
        case .paused: "Pause"
        }
    }

    public var caption: String {
        switch self {
        case .speakFreely: "Chime in any time"
        case .mentionsOnly: "Only speaks if you @mention or say name"
        case .paused: "Go offline, use no credits"
        }
    }

    /// The mark for this level. It carries the level on its own in the
    /// composer, where there is no room for the title — so each one has to read
    /// as its own idea at a glance: sound, a name, a stop.
    public var iconSystemName: String {
        switch self {
        case .speakFreely: "speaker.wave.2"
        case .mentionsOnly: "at"
        case .paused: "pause.circle"
        }
    }

    /// Wire value for the control plane (speak / mention / paused).
    public var wireMode: String {
        switch self {
        case .speakFreely: "speak"
        case .mentionsOnly: "mention"
        case .paused: "paused"
        }
    }

    /// The level a conversation is in until someone sets one. Matches the
    /// control plane's default, so an unset room and an explicit Speak freely
    /// render identically — because they behave identically.
    public static let `default`: AgentParticipationLevel = .speakFreely

    public init?(wireMode: String) {
        switch wireMode {
        case "speak": self = .speakFreely
        case "mention": self = .mentionsOnly
        case "paused": self = .paused
        default: return nil
        }
    }
}

#endif
