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
    private var pendingWrites: [String: CheckedContinuation<Void, Never>] = [:]
    private var holdsWrites: Bool = false

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

    func holdWrites(_ holds: Bool) {
        holdsWrites = holds
    }

    func releaseWrite(_ model: String) {
        pendingWrites.removeValue(forKey: model)?.resume()
    }

    func waitForPendingWrite(_ model: String) async {
        while pendingWrites[model] == nil {
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
        if holdsWrites {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingWrites[model] = continuation
            }
        }
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

    /// Another member's switch arriving mid-write is not thrown away when the
    /// write lands. Both devices write the group's appData, so the room can
    /// converge on theirs — and when it does, the value the room carries is the
    /// one already observed here, so no further change arrives to correct a
    /// picker that kept the local tap.
    func testSyncedModelDuringWriteIsAdoptedWhenTheWriteLands() async {
        let service = ScriptedModelService(serverModel: nil, catalogue: catalogue)
        await service.holdWrites(true)
        let store = AgentModelStore(
            instanceId: "instance-1",
            service: service
        )

        store.select(catalogue[0])
        await service.waitForPendingWrite(catalogue[0].id)
        store.apply(syncedModel: catalogue[1].id)
        // Held, not adopted: the write this device made is still unanswered.
        XCTAssertEqual(store.selectedId, catalogue[0].id)

        await service.releaseWrite(catalogue[0].id)
        while store.selectedId == catalogue[0].id {
            await Task.yield()
        }
        XCTAssertEqual(store.selectedId, catalogue[1].id)
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
