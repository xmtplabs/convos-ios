import ConvosComposer
import XCTest
@testable import Convos

/// A participation service a test can hold still. Every call parks on a
/// continuation until the test releases it, so reads and writes can be
/// interleaved deliberately instead of hoping a sleep lands in the right order.
private actor ScriptedParticipationService: AgentParticipationServing {
    struct WriteFailure: Error {}

    private var serverMode: String = "speak"
    private var failingModes: Set<String> = []
    /// Every call that reached the service, in the order it arrived - the record
    /// that shows whether writes were serialized or raced.
    private(set) var startedModes: [String] = []
    private(set) var writtenModes: [String] = []
    private var pendingWrites: [String: CheckedContinuation<Void, Never>] = [:]
    private var pendingReads: [CheckedContinuation<Void, Never>] = []
    private var holdsWrites: Bool = false
    private var holdsReads: Bool = false

    func setServerMode(_ mode: String) {
        serverMode = mode
    }

    func failWrites(of modes: Set<String>) {
        failingModes = modes
    }

    func holdWrites(_ holds: Bool) {
        holdsWrites = holds
    }

    func holdReads(_ holds: Bool) {
        holdsReads = holds
    }

    func releaseWrite(_ mode: String) {
        pendingWrites.removeValue(forKey: mode)?.resume()
    }

    func releaseReads() {
        let waiting = pendingReads
        pendingReads = []
        waiting.forEach { $0.resume() }
    }

    func waitForPendingWrite(_ mode: String) async {
        while pendingWrites[mode] == nil {
            await Task.yield()
        }
    }

    func waitForPendingRead() async {
        while pendingReads.isEmpty {
            await Task.yield()
        }
    }

    func readMode(conversationId: String, variantId: String?) async throws -> String {
        if holdsReads {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingReads.append(continuation)
            }
        }
        return serverMode
    }

    func writeMode(_ mode: String, conversationId: String, variantId: String?) async throws {
        startedModes.append(mode)
        if holdsWrites {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingWrites[mode] = continuation
            }
        }
        writtenModes.append(mode)
        if failingModes.contains(mode) {
            throw WriteFailure()
        }
        serverMode = mode
    }
}

@MainActor
final class AgentParticipationStoreStressTests: XCTestCase {
    private func makeStore(
        service: ScriptedParticipationService
    ) -> AgentParticipationStore {
        AgentParticipationStore(conversationId: "convo-1", service: service)
    }

    /// A tap that lands while a read is in flight owns the level: the value the
    /// read was already fetching is older than the tap.
    func testTapDuringReadSurvivesTheRead() async {
        let service = ScriptedParticipationService()
        await service.setServerMode("speak")
        await service.holdReads(true)
        let store = makeStore(service: service)

        let load = Task { await store.load() }
        await service.waitForPendingRead()
        await store.set(.paused)
        await service.releaseReads()
        await load.value

        XCTAssertEqual(store.level, .paused)
    }

    /// The mirror case, and the one a member hits by pulling the sheet open
    /// again right after tapping: a read that starts while a write is still in
    /// flight sees the pre-write server value, and must not resurrect it.
    func testReadStartedDuringPendingWriteDoesNotResurrectOldValue() async {
        let service = ScriptedParticipationService()
        await service.setServerMode("speak")
        await service.holdWrites(true)
        let store = makeStore(service: service)

        let write = Task { await store.set(.paused) }
        await service.waitForPendingWrite("paused")
        await store.load()

        XCTAssertEqual(store.level, .paused, "a refresh mid-write must not show the pre-write level")

        await service.releaseWrite("paused")
        await write.value
        XCTAssertEqual(store.level, .paused)
    }

    /// Two taps in quick succession: they reach the server one at a time and in
    /// the order they were tapped, so the level the member last chose is the one
    /// the server ends on - not whichever call the network happened to deliver
    /// last.
    func testRapidSwitchingSettlesOnTheLastTap() async {
        let service = ScriptedParticipationService()
        await service.holdWrites(true)
        let store = makeStore(service: service)

        let first = Task { await store.set(.paused) }
        await service.waitForPendingWrite("paused")
        let second = Task { await store.set(.mentionsOnly) }
        await Task.yield()

        let startedWhileFirstHeld = await service.startedModes
        XCTAssertEqual(startedWhileFirstHeld, ["paused"], "the second write must wait its turn")

        await service.releaseWrite("paused")
        await service.waitForPendingWrite("mention")
        await service.releaseWrite("mention")
        await first.value
        await second.value

        XCTAssertEqual(store.level, .mentionsOnly)
        let written = await service.writtenModes
        XCTAssertEqual(written, ["paused", "mention"], "the server must see the taps in order")
    }

    /// A tap that is already superseded by the time its turn comes never goes
    /// out: sending it would walk the agents through a level the member left
    /// while they waited.
    func testSupersededTapIsNeverSent() async {
        let service = ScriptedParticipationService()
        await service.holdWrites(true)
        let store = makeStore(service: service)

        let first = Task { await store.set(.paused) }
        await service.waitForPendingWrite("paused")
        let skipped = Task { await store.set(.mentionsOnly) }
        let last = Task { await store.set(.speakFreely) }
        await Task.yield()

        await service.releaseWrite("paused")
        await service.waitForPendingWrite("speak")
        await service.releaseWrite("speak")
        await first.value
        await skipped.value
        await last.value

        XCTAssertEqual(store.level, .speakFreely)
        let written = await service.writtenModes
        XCTAssertEqual(written, ["paused", "speak"], "the middle tap was already stale")
    }

    /// A failed write returns the control to the level the server actually
    /// acknowledged. Rolling back to whatever `level` held at tap time can land
    /// on an optimistic value from an earlier write that never itself landed -
    /// a level the conversation was never in.
    func testRollbackReturnsToTheConfirmedLevel() async {
        let service = ScriptedParticipationService()
        await service.setServerMode("speak")
        let store = makeStore(service: service)
        await store.load()

        await service.holdWrites(true)
        await service.failWrites(of: ["paused", "mention"])
        let firstFailure = Task { await store.set(.paused) }
        await service.waitForPendingWrite("paused")
        let secondFailure = Task { await store.set(.mentionsOnly) }
        await Task.yield()

        await service.releaseWrite("paused")
        await service.waitForPendingWrite("mention")
        await service.releaseWrite("mention")
        await firstFailure.value
        await secondFailure.value

        XCTAssertEqual(store.level, .speakFreely, "rollback must not land on the unconfirmed Pause")
    }

    /// A failed write rolls back only if it is still the newest one. When a newer
    /// tap has already moved the control, rolling back would drag the member to a
    /// level they just left.
    func testFailedWriteDoesNotClobberNewerTap() async {
        let service = ScriptedParticipationService()
        await service.holdWrites(true)
        await service.failWrites(of: ["paused"])
        let store = makeStore(service: service)

        let failing = Task { await store.set(.paused) }
        await service.waitForPendingWrite("paused")
        let newer = Task { await store.set(.mentionsOnly) }
        await Task.yield()

        await service.releaseWrite("paused")
        await failing.value
        await service.waitForPendingWrite("mention")
        await service.releaseWrite("mention")
        await newer.value

        XCTAssertEqual(store.level, .mentionsOnly, "the older failure must not pull the level back")
    }

    /// The plain failure path still stands: nothing newer, so the control returns
    /// to where the agents actually are and says so.
    func testLoneFailedWriteRollsBackAndReports() async {
        let service = ScriptedParticipationService()
        await service.failWrites(of: ["paused"])
        let store = makeStore(service: service)

        await store.set(.paused)

        XCTAssertEqual(store.level, .default)
        XCTAssertNotNil(store.errorMessage)
    }

    /// Churn: many switches back to back, then a refresh. The control ends on the
    /// last tap and agrees with the server.
    func testSwitchChurnEndsConsistentWithTheServer() async {
        let service = ScriptedParticipationService()
        let store = makeStore(service: service)
        let sequence: [AgentParticipationLevel] = [
            .paused, .mentionsOnly, .speakFreely, .paused, .mentionsOnly, .paused, .speakFreely, .mentionsOnly,
        ]

        for level in sequence {
            await store.set(level)
        }
        await store.load()

        XCTAssertEqual(store.level, sequence[sequence.count - 1])
        let written = await service.writtenModes
        XCTAssertEqual(written.count, sequence.count, "every switch must reach the server once")
    }

    /// Repeated refreshes are stable and mark the store loaded.
    func testRepeatedLoadsAreStable() async {
        let service = ScriptedParticipationService()
        await service.setServerMode("mention")
        let store = makeStore(service: service)

        for _ in 0..<10 {
            await store.load()
        }

        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.level, .mentionsOnly)
    }
}
