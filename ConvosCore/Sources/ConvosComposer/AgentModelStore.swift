#if canImport(UIKit)
import ConvosCore
import Foundation

/// One model an agent can be switched to, as the agent's own config lists it.
///
/// Deliberately not an enum: the catalogue is per agent and comes from the
/// backend, so a build that hardcoded it would drift the moment an agent's
/// list changed and would offer models a given agent cannot run.
public struct AgentModelOption: Identifiable, Hashable, Sendable {
    /// The model id the runtime routes on.
    public let id: String
    /// The display name the agent's own config carries.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What one agent's model surface looks like right now.
public struct AgentModelSnapshot: Sendable {
    /// The model the agent is set to, or nil when nobody has switched it —
    /// it is running whatever its template shipped.
    public let model: String?
    /// The catalogue. Empty before the agent has ever run, since the list
    /// lives inside its container.
    public let available: [AgentModelOption]

    public init(model: String?, available: [AgentModelOption]) {
        self.model = model
        self.available = available
    }
}

/// The one read and one write the model picker makes. Narrow on purpose, so a
/// test can drive them slowly, out of order, or into failure.
public protocol AgentModelServing: Sendable {
    func readModel(instanceId: String, variantId: String?) async throws -> AgentModelSnapshot
    func writeModel(
        _ model: String,
        instanceId: String,
        variantId: String?
    ) async throws -> AgentModelSnapshot
}

/// The real service: the backend proxy, which holds the control-plane key.
public struct ControlPlaneAgentModelService: AgentModelServing {
    public init() {}

    public func readModel(
        instanceId: String,
        variantId: String?
    ) async throws -> AgentModelSnapshot {
        snapshot(
            from: try await client().getAgentModel(
                instanceId: instanceId,
                variantId: variantId
            )
        )
    }

    public func writeModel(
        _ model: String,
        instanceId: String,
        variantId: String?
    ) async throws -> AgentModelSnapshot {
        snapshot(
            from: try await client().setAgentModel(
                instanceId: instanceId,
                model: model,
                variantId: variantId
            )
        )
    }

    private func snapshot(from response: ConvosAPI.AgentModelResponse) -> AgentModelSnapshot {
        AgentModelSnapshot(
            model: response.model,
            available: (response.available ?? []).map {
                AgentModelOption(id: $0.id, name: $0.name)
            }
        )
    }

    private func client() -> any ConvosAPIClientProtocol {
        ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
    }
}

/// Owns one agent's model for the picker that renders it.
///
/// Same shape as `AgentParticipationStore`, and for the same reasons: a tap has
/// to show immediately, a failed write has to roll back to what the server
/// actually holds, and two taps in flight together must not let the older one
/// win.
@Observable
@MainActor
public final class AgentModelStore {
    /// The catalogue to render. Empty until the first read resolves — the app
    /// does not invent options, because a model this agent cannot run would be
    /// refused upstream and read to the member as the picker being broken.
    public private(set) var options: [AgentModelOption] = []

    /// The model id the agent is set to, or nil when nobody has switched it.
    public private(set) var selectedId: String?

    /// False until the first read resolves, so a control can hold its place
    /// rather than claim a model it does not know yet. Set once the read
    /// finishes either way.
    public private(set) var hasLoaded: Bool = false

    /// Set when a write failed and was rolled back, so the host can surface it.
    public private(set) var errorMessage: String?

    private let instanceId: String
    private let variantId: String?
    private let service: any AgentModelServing

    /// Bumped on every local `select()`. `load()` captures it before its read
    /// and bails if it changed meanwhile, so a tap that lands mid-read is never
    /// clobbered by the older server value the read was already fetching.
    private var writeGeneration: Int = 0

    /// Writes issued and not yet answered. A read overlapping one is reading
    /// from before it lands, so its value is already behind the member's tap
    /// even though no generation changed while it was in flight.
    private var writesInFlight: Int = 0

    /// The newest model the server has acknowledged. A failed write returns
    /// here rather than to whatever was shown before the tap — that earlier
    /// value may itself be an optimistic one that never landed.
    private var confirmedId: String?

    /// The tail of the write queue. Each write waits for the one before it, so
    /// the order the member tapped in is the order the server sees.
    private var writeChain: Task<Void, Never>?

    /// The newest synced value that arrived while a write was outstanding, held
    /// so a failed write can roll back to it instead of to the older value the
    /// server acknowledged before the sync. Double-optional on purpose: the
    /// outer nil means "nothing arrived", the inner nil means "the room says no
    /// model", and those are different answers.
    private var deferredSyncedModel: String??

    public init(
        instanceId: String,
        variantId: String? = nil,
        service: any AgentModelServing = ControlPlaneAgentModelService()
    ) {
        self.instanceId = instanceId
        self.variantId = variantId
        self.service = service
    }

    /// The name to show for what the agent is on.
    ///
    /// Falls back to the raw id for a model the catalogue does not carry: an
    /// agent switched from chat can be on anything in its own list, and naming
    /// it honestly beats showing a different model's name.
    public var selectedTitle: String? {
        guard let selectedId else { return nil }
        return options.first { $0.id == selectedId }?.name ?? selectedId
    }

    /// Adopts a model that arrived over the network — someone switched this
    /// agent on another device and the synced conversation carries their value.
    ///
    /// The counterpart of `AgentParticipationStore.apply(syncedLevel:)`, and
    /// ignored under the same condition: a write outstanding on this device is
    /// newer than anything the sync can be carrying, and this device's own
    /// change arrives back here as a synced value a moment later anyway.
    ///
    /// Does not touch `options`. The catalogue is what this agent *can* run and
    /// lives in its container; only the choice travels in group state.
    public func apply(syncedModel: String?) {
        hasLoaded = true
        guard writesInFlight == 0 else {
            // Held, not discarded. If the write now in flight fails it rolls
            // back to what the server last acknowledged — and without this the
            // rollback would restore a model the room has since moved off,
            // leaving the picker on a value nothing will correct.
            deferredSyncedModel = .some(syncedModel)
            return
        }
        deferredSyncedModel = nil
        confirmedId = syncedModel
        selectedId = syncedModel
    }

    /// Reads the agent's model and catalogue. Safe to call on every appearance.
    public func load() async {
        let generation = writeGeneration
        let inFlight = writesInFlight
        do {
            let snapshot = try await service.readModel(
                instanceId: instanceId,
                variantId: variantId
            )
            // The catalogue is not a member's choice, so it applies regardless
            // of a tap that raced this read.
            if !snapshot.available.isEmpty { options = snapshot.available }
            // A tap landed while this was in flight; its value is newer than
            // anything this read can be carrying.
            guard writeGeneration == generation, writesInFlight == inFlight else {
                hasLoaded = true
                return
            }
            selectedId = snapshot.model
            confirmedId = snapshot.model
        } catch {
            Log.error("agent model read failed: \(error)")
        }
        hasLoaded = true
    }

    /// Picks a model: optimistic locally, serialized on the wire.
    public func select(_ option: AgentModelOption) {
        guard option.id != selectedId else { return }
        writeGeneration += 1
        let generation = writeGeneration
        selectedId = option.id
        errorMessage = nil
        writesInFlight += 1

        let previousWrite = writeChain
        writeChain = Task { [weak self] in
            await previousWrite?.value
            await self?.write(option, generation: generation)
        }
    }

    private func write(_ option: AgentModelOption, generation: Int) async {
        defer { writesInFlight -= 1 }
        // Read here, not when the tap was queued. A tap queued behind another
        // is queued before that one is acknowledged, so `confirmedId` then is
        // still the model from two taps ago — rolling back to it would name a
        // model the server has since moved off. By the time this runs the write
        // ahead of it has settled, and this is what the server actually holds.
        let previous = confirmedId
        do {
            let snapshot = try await service.writeModel(
                option.id,
                instanceId: instanceId,
                variantId: variantId
            )
            if !snapshot.available.isEmpty { options = snapshot.available }
            confirmedId = option.id
            // This tap is what the server holds now, so anything that synced
            // while it was in flight is older than it and must not survive to
            // be restored by a later rollback.
            deferredSyncedModel = nil
            Log.info("agent model set to \(option.id)")
        } catch {
            Log.error("agent model update failed: \(error)")
            // Roll back only while this is still the newest tap — a newer one
            // already owns what the picker shows.
            guard writeGeneration == generation else { return }
            // A synced value that landed while this write was out is newer than
            // what the server acknowledged before it, so it wins the rollback.
            let target = deferredSyncedModel ?? previous
            deferredSyncedModel = nil
            selectedId = target
            confirmedId = target
            let previousName = target.map { id in
                options.first { $0.id == id }?.name ?? id
            }
            errorMessage = previousName.map {
                "Couldn't change the model. The agent is still on \($0)."
            } ?? "Couldn't change the model."
        }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
#endif
