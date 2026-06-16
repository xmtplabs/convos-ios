@testable import ConvosCore
import Foundation
import Testing

/// Coverage for `SessionManager.awaitProvisionedAgentInbox` — the direct-add
/// provision + registration poll. Before this the loop was untested: the API
/// stubs returned a non-nil `inboxId` on the provision call, so the
/// `while`-poll never iterated and `getAgentJoinStatus` was never exercised.
///
/// The helper takes plain closures for the two API calls plus injectable
/// `now`/`sleep`, so each branch (fast path, poll-until-registered, terminal
/// statuses, unknown status, deadline) is driven deterministically with no
/// real waiting.
@Suite("Direct-add provision poll")
struct DirectAddProvisionPollTests {
    /// Thread-safe mutable cell so the `@Sendable` closures can record calls
    /// and advance a logical clock.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        @discardableResult func mutate<R>(_ body: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }; return body(&value)
        }
    }

    private func provisionResponse(
        instanceId: String? = "instance-1",
        inboxId: String? = nil
    ) -> ConvosAPI.AgentJoinResponse {
        ConvosAPI.AgentJoinResponse(
            success: true,
            joined: false,
            instanceId: instanceId,
            inboxId: inboxId
        )
    }

    private func statusResponse(
        instanceId: String = "instance-1",
        joinStatus: String,
        inboxId: String? = nil,
        joinFailureReason: String? = nil
    ) -> ConvosAPI.AgentJoinStatusResponse {
        ConvosAPI.AgentJoinStatusResponse(
            success: true,
            instanceId: instanceId,
            joinStatus: joinStatus,
            joined: joinStatus == "joined" || joinStatus == "ready",
            inboxId: inboxId,
            joinFailureReason: joinFailureReason
        )
    }

    @Test("Fast path: inbox already on the provision response — no polling")
    func fastPathSkipsPoll() async throws {
        let statusCalls = Box(0)
        let resolved = try await SessionManager.awaitProvisionedAgentInbox(
            sleep: { _ in },
            requestJoin: { self.provisionResponse(inboxId: "agent-inbox") },
            fetchStatus: { _ in statusCalls.mutate { $0 += 1 }; return self.statusResponse(joinStatus: "joined", inboxId: "agent-inbox") }
        )
        #expect(resolved.inboxId == "agent-inbox")
        #expect(resolved.instanceId == "instance-1")
        #expect(statusCalls.get() == 0, "Inbox present on provision must short-circuit the poll")
    }

    @Test("Polls until the inbox registers, then returns it")
    func pollsUntilRegistered() async throws {
        let statusCalls = Box(0)
        let resolved = try await SessionManager.awaitProvisionedAgentInbox(
            sleep: { _ in },
            requestJoin: { self.provisionResponse(inboxId: nil) },
            fetchStatus: { _ in
                let n = statusCalls.mutate { $0 += 1; return $0 }
                // Registration in flight for the first two polls, then the
                // inbox lands — status legitimately stays "starting" since the
                // agent has not *joined* yet (that happens after addMembers).
                return n < 3
                    ? self.statusResponse(joinStatus: "starting", inboxId: nil)
                    : self.statusResponse(joinStatus: "starting", inboxId: "agent-inbox")
            }
        )
        #expect(resolved.inboxId == "agent-inbox")
        #expect(statusCalls.get() == 3, "Should poll until the inbox appears")
    }

    @Test("`failed` status is terminal — throws immediately, no spin to deadline")
    func failedIsTerminal() async throws {
        let statusCalls = Box(0)
        await #expect(throws: APIError.self) {
            _ = try await SessionManager.awaitProvisionedAgentInbox(
                sleep: { _ in },
                requestJoin: { self.provisionResponse(inboxId: nil) },
                fetchStatus: { _ in
                    statusCalls.mutate { $0 += 1 }
                    return self.statusResponse(joinStatus: "failed", joinFailureReason: "boom")
                }
            )
        }
        #expect(statusCalls.get() == 1, "A terminal status must stop the poll on the first observation")
    }

    @Test("`no_agents_available` surfaces as noAgentsAvailable, not a timeout")
    func noAgentsAvailableIsTerminal() async throws {
        var caught: APIError?
        do {
            _ = try await SessionManager.awaitProvisionedAgentInbox(
                sleep: { _ in },
                requestJoin: { self.provisionResponse(inboxId: nil) },
                fetchStatus: { _ in self.statusResponse(joinStatus: "no_agents_available") }
            )
        } catch let error as APIError {
            caught = error
        }
        guard case .noAgentsAvailable = caught else {
            Issue.record("Expected APIError.noAgentsAvailable, got \(String(describing: caught))")
            return
        }
    }

    @Test("An unmodeled status keeps polling rather than throwing or exiting early")
    func unknownStatusKeepsPolling() async throws {
        let statusCalls = Box(0)
        let resolved = try await SessionManager.awaitProvisionedAgentInbox(
            sleep: { _ in },
            requestJoin: { self.provisionResponse(inboxId: nil) },
            fetchStatus: { _ in
                let n = statusCalls.mutate { $0 += 1; return $0 }
                return n < 2
                    ? self.statusResponse(joinStatus: "queued", inboxId: nil)  // not modeled → .unknown
                    : self.statusResponse(joinStatus: "starting", inboxId: "agent-inbox")
            }
        )
        #expect(resolved.inboxId == "agent-inbox")
        #expect(statusCalls.get() == 2)
    }

    @Test("Times out with agentPoolTimeout when the inbox never registers")
    func timesOut() async throws {
        // Logical clock advanced by `sleep` so the 30s deadline is reached
        // without real waiting.
        let clock = Box(Date(timeIntervalSince1970: 0))
        var caught: APIError?
        do {
            _ = try await SessionManager.awaitProvisionedAgentInbox(
                now: { clock.get() },
                sleep: { dt in clock.mutate { $0 = $0.addingTimeInterval(dt) } },
                requestJoin: { self.provisionResponse(inboxId: nil) },
                fetchStatus: { _ in self.statusResponse(joinStatus: "starting", inboxId: nil) }
            )
        } catch let error as APIError {
            caught = error
        }
        guard case .agentPoolTimeout = caught else {
            Issue.record("Expected APIError.agentPoolTimeout, got \(String(describing: caught))")
            return
        }
    }

    @Test("Missing instanceId on the provision response fails fast")
    func missingInstanceIdThrows() async throws {
        var caught: APIError?
        do {
            _ = try await SessionManager.awaitProvisionedAgentInbox(
                sleep: { _ in },
                requestJoin: { self.provisionResponse(instanceId: nil, inboxId: nil) },
                fetchStatus: { _ in self.statusResponse(joinStatus: "starting") }
            )
        } catch let error as APIError {
            caught = error
        }
        guard case .agentProvisionFailed = caught else {
            Issue.record("Expected APIError.agentProvisionFailed, got \(String(describing: caught))")
            return
        }
    }
}
