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

/// The real service. The mode lives in the conversation's XMTP group appData, so
/// a read is a read of already-synced group state - no request, and current the
/// moment the member opens the conversation, including a member who just joined.
///
/// The write goes out as a group-metadata commit, which is also what tells the
/// other members: their `ConversationWriter` re-reads appData off the commit and
/// their control follows. It is mirrored to the participation endpoint on a best
/// effort basis so the agent runtime's server-side wake gate stays current until
/// it reads the mode off the group itself; a failed mirror does not fail the
/// write, because appData is the authoritative copy.
public struct ConversationAppDataParticipationService: AgentParticipationServing {
    private let metadataWriter: any ConversationMetadataWriterProtocol

    /// The mode the conversation carried when this service was built. The host
    /// observes the conversation and pushes later modes into the store with
    /// `apply(syncedLevel:)`, so this is a starting point, not the live value.
    private let mode: ConversationParticipationMode

    public init(
        metadataWriter: any ConversationMetadataWriterProtocol,
        mode: ConversationParticipationMode
    ) {
        self.metadataWriter = metadataWriter
        self.mode = mode
    }

    public func readMode(conversationId: String, variantId: String?) async throws -> String {
        mode.rawValue
    }

    public func writeMode(_ mode: String, conversationId: String, variantId: String?) async throws {
        guard let participationMode = ConversationParticipationMode(rawValue: mode) else {
            throw AgentParticipationServiceError.unknownMode(mode)
        }
        try await metadataWriter.updateParticipationMode(participationMode, for: conversationId)
        await mirrorToControlPlane(mode, conversationId: conversationId, variantId: variantId)
    }

    private func mirrorToControlPlane(_ mode: String, conversationId: String, variantId: String?) async {
        do {
            _ = try await ConvosAPIClientFactory
                .client(environment: ConfigManager.shared.currentEnvironment)
                .setAgentParticipation(
                    conversationId: conversationId,
                    mode: mode,
                    variantId: variantId
                )
        } catch {
            Log.warning("participation control-plane mirror failed: \(error)")
        }
    }
}

public enum AgentParticipationServiceError: Error {
    /// A mode this build does not recognize. Reachable only from a caller that
    /// invented a wire value; the menu can only produce known ones.
    case unknownMode(String)
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

    /// The newest level the server has acknowledged. `level` runs ahead of it
    /// the moment someone taps, and a failed write returns to this rather than
    /// to whatever `level` held before the tap - that earlier value may itself
    /// be an optimistic one that never landed, and rolling back to it would put
    /// the control on a level the conversation was never in.
    private var confirmedLevel: AgentParticipationLevel = .default

    /// The tail of the write queue. Each write waits for the one before it, so
    /// the order the member tapped in is the order the server sees. Without
    /// this the calls race and the last tap is whichever the network delivers
    /// last, which is how the level ends up quietly reverting on the next read.
    private var writeChain: Task<Void, Never>?

    private let service: any AgentParticipationServing

    public init(
        conversationId: String,
        variantId: String? = nil,
        service: any AgentParticipationServing
    ) {
        self.conversationId = conversationId
        self.variantId = variantId
        self.service = service
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// Adopts a level that arrived over the network - another member changed the
    /// mode and the synced conversation carries their value now.
    ///
    /// Ignored while this device has a write outstanding: that member's tap is
    /// newer than any state the sync could be carrying, and their own commit
    /// arrives back here as a synced change a moment later anyway.
    public func apply(syncedLevel: AgentParticipationLevel) {
        hasLoaded = true
        guard writesInFlight == 0 else { return }
        confirmedLevel = syncedLevel
        level = syncedLevel
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
                confirmedLevel = loaded
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
        guard newLevel != level else { return }
        level = newLevel
        writeGeneration += 1
        let generation = writeGeneration
        writesInFlight += 1
        let precedingWrite = writeChain
        let write = Task { @MainActor [weak self] in
            await precedingWrite?.value
            await self?.sendLevel(newLevel, generation: generation)
        }
        writeChain = write
        await write.value
        writesInFlight -= 1
    }

    /// One write, once it holds its turn in the queue.
    private func sendLevel(_ newLevel: AgentParticipationLevel, generation: Int) async {
        // Taps that piled up behind this one already moved the control past this
        // level. Sending it would walk the agents through a level the member
        // left while waiting, and the newest tap is still queued to say where
        // they actually want them.
        guard writeGeneration == generation else { return }
        do {
            try await service.writeMode(
                newLevel.wireMode,
                conversationId: conversationId,
                variantId: variantId
            )
            confirmedLevel = newLevel
            Log.info("participation set mode=\(newLevel.wireMode)")
        } catch {
            Log.error("participation update failed: \(error)")
            // A newer tap arrived while this write was out. Rolling back now
            // would drag the member to a level they left, and that newer write
            // reports its own outcome.
            guard writeGeneration == generation else { return }
            level = confirmedLevel
            errorMessage = "Couldn't update participation. The agents are still on their previous setting."
        }
    }
}
#endif
