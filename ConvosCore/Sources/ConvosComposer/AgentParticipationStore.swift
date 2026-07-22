#if canImport(UIKit)
import ConvosCore
import Foundation

/// Owns one conversation's participation level for the views that show it.
///
/// Two surfaces render this — the bubble in the composer and the row in an
/// agent's profile — and both have to agree, load it the same way, and fail the
/// same way. Keeping the level and its two calls here means neither surface
/// carries its own copy of the optimistic-write dance.
@Observable
@MainActor
public final class AgentParticipationStore {
    /// The level to render. Starts at the product default so the control is
    /// never blank; replaced by the conversation's real level once read.
    public private(set) var level: AgentParticipationLevel = .default

    /// Set when a write failed and was rolled back, so the host can surface it.
    /// Cleared by `dismissError()` — the host owns the alert, not this store.
    public private(set) var errorMessage: String?

    private let conversationId: String

    public init(conversationId: String) {
        self.conversationId = conversationId
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// Reads the level the conversation is in. Any member may have set it, so
    /// this is the only honest source — a device-local memory goes stale the
    /// moment someone else changes it.
    ///
    /// Quiet on failure: the default is a safe thing to show, and an error for
    /// a read the member never asked for is noise.
    public func load() async {
        do {
            let response = try await client().getAgentParticipation(
                conversationId: conversationId
            )
            if let loaded = AgentParticipationLevel(wireMode: response.mode) {
                level = loaded
            }
        } catch {
            Log.error("participation read failed: \(error)")
        }
    }

    /// Applies a level to every agent in the conversation.
    ///
    /// Optimistic, and rolled back when the write fails: the control moves
    /// immediately because that is what a tap should feel like, but if the
    /// write never lands the agents are still on the old level — leaving the
    /// check on the new one would tell the member the opposite of the error.
    public func set(_ newLevel: AgentParticipationLevel) async {
        let previous = level
        guard newLevel != previous else { return }
        level = newLevel
        do {
            _ = try await client().setAgentParticipation(
                conversationId: conversationId,
                mode: newLevel.wireMode
            )
            Log.info("participation set mode=\(newLevel.wireMode)")
        } catch {
            Log.error("participation update failed: \(error)")
            level = previous
            errorMessage = "Couldn't update participation. The agents are still on their previous setting."
        }
    }

    private func client() -> any ConvosAPIClientProtocol {
        ConvosAPIClientFactory.client(
            environment: ConfigManager.shared.currentEnvironment
        )
    }
}
#endif
