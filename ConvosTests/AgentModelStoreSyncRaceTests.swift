import ConvosComposer
import XCTest
@testable import Convos

/// A model service a test can hold still: the read parks on a continuation
/// until the test releases it, so a synced value can be delivered while the
/// read is provably in flight rather than hoping a sleep lands in the gap.
private actor ScriptedModelService: AgentModelServing {
    private var serverModel: String?
    private let catalogue: [AgentModelOption]
    private var pendingReads: [CheckedContinuation<Void, Never>] = []
    private var holdsReads: Bool = false

    init(serverModel: String?, catalogue: [AgentModelOption]) {
        self.serverModel = serverModel
        self.catalogue = catalogue
    }

    func holdReads(_ holds: Bool) {
        holdsReads = holds
    }

    func releaseReads() {
        let waiting = pendingReads
        pendingReads = []
        waiting.forEach { $0.resume() }
    }

    func waitForPendingRead() async {
        while pendingReads.isEmpty {
            await Task.yield()
        }
    }

    func readModel(instanceId: String, variantId: String?) async throws -> AgentModelSnapshot {
        if holdsReads {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingReads.append(continuation)
            }
        }
        return AgentModelSnapshot(model: serverModel, available: catalogue)
    }

    func writeModel(
        _ model: String,
        instanceId: String,
        variantId: String?
    ) async throws -> AgentModelSnapshot {
        serverModel = model
        return AgentModelSnapshot(model: model, available: catalogue)
    }
}

@MainActor
final class AgentModelStoreSyncRaceTests: XCTestCase {
    private let catalogue = [
        AgentModelOption(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5"),
        AgentModelOption(id: "openai/gpt-5.6-sol", name: "GPT-5.6 Sol"),
    ]

    /// Someone else's switch arriving mid-read owns the picker. The read was
    /// already fetching the model the control plane held before the switch, so
    /// letting its answer land would put the picker back on the old model and
    /// leave it there until something else refreshed it.
    func testSyncedModelDuringReadSurvivesTheRead() async {
        let service = ScriptedModelService(
            serverModel: "anthropic/claude-sonnet-5",
            catalogue: catalogue
        )
        await service.holdReads(true)
        let store = AgentModelStore(
            instanceId: "instance-1",
            service: service
        )

        let load = Task { await store.load() }
        await service.waitForPendingRead()
        store.apply(syncedModel: "openai/gpt-5.6-sol")
        await service.releaseReads()
        await load.value

        XCTAssertEqual(store.selectedId, "openai/gpt-5.6-sol")
        // The catalogue is not a member's choice, so the read still delivers it.
        XCTAssertEqual(store.options.map(\.id), catalogue.map(\.id))
    }

    /// The room clearing a model is a value like any other: a read that was
    /// already fetching the old one must not put it back.
    func testSyncedClearDuringReadSurvivesTheRead() async {
        let service = ScriptedModelService(
            serverModel: "anthropic/claude-sonnet-5",
            catalogue: catalogue
        )
        await service.holdReads(true)
        let store = AgentModelStore(
            instanceId: "instance-1",
            service: service
        )

        let load = Task { await store.load() }
        await service.waitForPendingRead()
        store.apply(syncedModel: nil)
        await service.releaseReads()
        await load.value

        XCTAssertNil(store.selectedId)
    }
}
