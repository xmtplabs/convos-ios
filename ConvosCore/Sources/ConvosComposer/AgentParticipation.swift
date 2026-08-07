#if canImport(UIKit)
import ConvosCore
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

    /// The levels the menu offers — every level there is.
    public static var selectableCases: [AgentParticipationLevel] { allCases }

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

    /// Wire value for the control plane, and the value carried in the group's
    /// appData - one vocabulary, so the mode reads the same wherever it travels.
    public var wireMode: String {
        mode.rawValue
    }

    /// The synced mode this level renders. `ConversationParticipationMode` is the
    /// stored and transmitted form; this enum is how the composer draws it.
    public var mode: ConversationParticipationMode {
        switch self {
        case .speakFreely: .speakFreely
        case .mentionsOnly: .mentionsOnly
        case .paused: .paused
        }
    }

    public init(mode: ConversationParticipationMode) {
        switch mode {
        case .speakFreely: self = .speakFreely
        case .mentionsOnly: self = .mentionsOnly
        case .paused: self = .paused
        }
    }

    /// The level a conversation is in until someone sets one. Matches the
    /// control plane's default, so an unset room and an explicit Speak freely
    /// render identically — because they behave identically.
    public static let `default`: AgentParticipationLevel = .speakFreely

    public init?(wireMode: String) {
        guard let mode = ConversationParticipationMode(rawValue: wireMode) else { return nil }
        self.init(mode: mode)
    }
}

#endif
