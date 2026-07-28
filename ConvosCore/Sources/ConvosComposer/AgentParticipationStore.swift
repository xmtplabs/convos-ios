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

    /// False until the first read resolves. Surfaces that `level` is still the
    /// placeholder default rather than this conversation's real setting, so a
    /// control can hold its place without claiming a level it doesn't know yet.
    /// Set once the read finishes either way: a failed read leaves the default,
    /// and the default is the honest thing to show.
    public private(set) var hasLoaded: Bool = false

    /// Set when a write failed and was rolled back, so the host can surface it.
    /// Cleared by `dismissError()` — the host owns the alert, not this store.
    public private(set) var errorMessage: String?

    private let conversationId: String

    /// Dev-only variant routing key. An agent built on a variant worker only
    /// exists there, so both participation calls must carry this or the backend
    /// routes them to the default worker and the write fails. Nil (and stripped
    /// in production) for a normal agent.
    private let variantId: String?

    /// Bumped on every local `set()`. `load()` captures it before its network
    /// read and bails if it changed meanwhile, so a tap that lands mid-read is
    /// never clobbered by the older server value the read was already fetching.
    private var writeGeneration: Int = 0

    public init(conversationId: String, variantId: String? = nil) {
        self.conversationId = conversationId
        self.variantId = variantId
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
        let generationAtStart = writeGeneration
        defer { hasLoaded = true }
        do {
            let response = try await client().getAgentParticipation(
                conversationId: conversationId,
                variantId: variantId
            )
            // A set() that landed while this read was in flight is newer than the
            // value the server just returned; don't overwrite it with stale data.
            guard writeGeneration == generationAtStart else { return }
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
        writeGeneration += 1
        do {
            _ = try await client().setAgentParticipation(
                conversationId: conversationId,
                mode: newLevel.wireMode,
                variantId: variantId
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
