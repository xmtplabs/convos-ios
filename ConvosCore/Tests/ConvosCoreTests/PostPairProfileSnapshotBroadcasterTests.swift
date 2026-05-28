@testable import ConvosCore
import Foundation
import os
import Testing

@Suite("PostPairProfileSnapshotBroadcaster Tests")
struct PostPairProfileSnapshotBroadcasterTests {
    /// Minimal `PostPairBroadcastMessaging` double: returns a scripted
    /// sequence of installation-id sets (one per poll) and records how
    /// many times the broadcast was invoked.
    private final class FakeBroadcastMessaging: PostPairBroadcastMessaging, @unchecked Sendable {
        private struct State {
            var snapshots: [[String]]
            var index: Int = 0
            var broadcastCallCount: Int = 0
        }
        private let state: OSAllocatedUnfairLock<State>
        let broadcastReturnValue: Int

        init(snapshots: [[String]], broadcastReturnValue: Int = 3) {
            self.state = OSAllocatedUnfairLock(initialState: State(snapshots: snapshots))
            self.broadcastReturnValue = broadcastReturnValue
        }

        var broadcastCallCount: Int {
            state.withLock { $0.broadcastCallCount }
        }

        func installationsSnapshot(refreshFromNetwork: Bool) async throws -> InstallationsSnapshot {
            let ids: [String] = state.withLock { s in
                // Hold on the last entry once the script is exhausted so
                // extra polls keep seeing the final state.
                let current = s.snapshots[min(s.index, s.snapshots.count - 1)]
                if s.index < s.snapshots.count - 1 { s.index += 1 }
                return current
            }
            return InstallationsSnapshot(
                inboxId: "inbox",
                currentInstallationId: "self",
                installations: ids.map { InstallationInfo(id: $0, createdAt: nil) }
            )
        }

        @discardableResult
        func broadcastProfileSnapshotsToAllGroups() async -> Int {
            state.withLock { $0.broadcastCallCount += 1 }
            return broadcastReturnValue
        }
    }

    private func makeBroadcaster(_ fake: FakeBroadcastMessaging) -> PostPairProfileSnapshotBroadcaster {
        // All-zero schedule so the test never sleeps; length controls how
        // many polls happen before giving up.
        PostPairProfileSnapshotBroadcaster(messagingService: fake, pollSchedule: [0, 0, 0])
    }

    @Test("Broadcasts when a new installation appears beyond the baseline")
    func broadcastsOnNewInstallation() async {
        // First poll already shows the joiner beyond the baseline.
        let fake = FakeBroadcastMessaging(snapshots: [["self", "joiner"]])
        let didRun = await makeBroadcaster(fake).runAfterPairing(baseline: ["self"])
        #expect(didRun)
        #expect(fake.broadcastCallCount == 1)
    }

    @Test("Skips the broadcast when no new installation appears")
    func skipsWhenNoNewInstallation() async {
        // Every poll returns only the baseline set -- nothing new.
        let fake = FakeBroadcastMessaging(snapshots: [["self"]])
        let didRun = await makeBroadcaster(fake).runAfterPairing(baseline: ["self"])
        #expect(!didRun)
        #expect(fake.broadcastCallCount == 0)
    }

    @Test("Waits for the joiner rather than firing on a pre-existing paired device")
    func waitsForJoinerNotExistingDevice() async {
        // Baseline already contains a previously-paired device. The joiner
        // only appears on the third poll. The broadcaster must wait for it
        // and not fire on the pre-existing device.
        let baseline: Set<String> = ["self", "oldDevice"]
        let fake = FakeBroadcastMessaging(snapshots: [
            ["self", "oldDevice"],
            ["self", "oldDevice"],
            ["self", "oldDevice", "joiner"]
        ])
        let didRun = await makeBroadcaster(fake).runAfterPairing(baseline: baseline)
        #expect(didRun)
        #expect(fake.broadcastCallCount == 1)
    }

    @Test("A baseline that already includes the joiner never broadcasts")
    func staleBaselineNeverBroadcasts() async {
        // Reproduces the original bug: if the baseline is captured after
        // the joiner is already visible, the diff finds nothing new.
        let fake = FakeBroadcastMessaging(snapshots: [["self", "joiner"]])
        let didRun = await makeBroadcaster(fake).runAfterPairing(baseline: ["self", "joiner"])
        #expect(!didRun)
        #expect(fake.broadcastCallCount == 0)
    }
}
