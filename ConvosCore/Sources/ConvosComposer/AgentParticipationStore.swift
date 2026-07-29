#if canImport(UIKit)
import ConvosCore
import Foundation

/// The two calls the participation control makes. Narrow on purpose: the store
/// needs one read and one write, and a seam this small is what lets a test drive
/// them slowly, out of order, or into failure.
public protocol AgentParticipationServing: Sendable {
    func readMode(conversationId: String, variantId: String?) async throws -> String
    func writeMode(_ mode: String, conversationId: String, variantId: String?) async throws
}

/// The real service, talking to the participation endpoints.
public struct APIAgentParticipationService: AgentParticipationServing {
    public init() {}

    public func readMode(conversationId: String, variantId: String?) async throws -> String {
        try await client().getAgentParticipation(
            conversationId: conversationId,
            variantId: variantId
        ).mode
    }

    public func writeMode(_ mode: String, conversationId: String, variantId: String?) async throws {
        _ = try await client().setAgentParticipation(
            conversationId: conversationId,
            mode: mode,
            variantId: variantId
        )
    }

    private func client() -> any ConvosAPIClientProtocol {
        ConvosAPIClientFactory.client(
            environment: ConfigManager.shared.currentEnvironment
        )
    }
}

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
    /// A failed write reads it too, and rolls back only while it is still the
    /// newest one - a newer tap already owns the level by then.
    private var writeGeneration: Int = 0

    /// Writes that have been issued and not yet answered. A read that overlaps
    /// one is reading from before it lands, so its value is already behind the
    /// member's tap even though no generation changed while it was in flight.
    private var writesInFlight: Int = 0

    private let service: any AgentParticipationServing

    public init(
        conversationId: String,
        variantId: String? = nil,
        service: any AgentParticipationServing = APIAgentParticipationService()
    ) {
        self.conversationId = conversationId
        self.variantId = variantId
        self.service = service
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
        let overlappedAWrite = writesInFlight > 0
        defer { hasLoaded = true }
        do {
            let mode = try await service.readMode(
                conversationId: conversationId,
                variantId: variantId
            )
            // Anything the member did around this read is newer than the value
            // the server just returned: a set() that landed while it was in
            // flight, or one still unanswered at either end of it. Keep theirs.
            guard writeGeneration == generationAtStart,
                  !overlappedAWrite,
                  writesInFlight == 0 else {
                return
            }
            if let loaded = AgentParticipationLevel(wireMode: mode) {
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
        let generation = writeGeneration
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            try await service.writeMode(
                newLevel.wireMode,
                conversationId: conversationId,
                variantId: variantId
            )
            Log.info("participation set mode=\(newLevel.wireMode)")
        } catch {
            Log.error("participation update failed: \(error)")
            // A newer tap has already moved the control since this write went
            // out. Rolling back now would drag the member to a level they left,
            // and the newer write reports its own outcome.
            guard writeGeneration == generation else { return }
            level = previous
            errorMessage = "Couldn't update participation. The agents are still on their previous setting."
        }
    }
}
#endif
