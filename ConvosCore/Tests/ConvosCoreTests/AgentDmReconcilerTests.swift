import Combine
@testable import ConvosCore
import Foundation
import os
import Testing

/// The eager agent-DM reconciler: a DM is created when a verified agent shows
/// up in the user's conversations, deduplicated at every layer, and a failed
/// creation is not retried within the session (the DM page's first-send path
/// is the fallback). See docs/plans/agent-dms.md.
@Suite("AgentDmReconciler", .serialized)
struct AgentDmReconcilerTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[(agent: String, origin: String?)]>(initialState: [])

        func record(_ agent: String, _ origin: String?) {
            lock.withLock { $0.append((agent, origin)) }
        }

        var calls: [(agent: String, origin: String?)] {
            lock.withLock { $0 }
        }
    }

    private func agentMember(inboxId: String, verified: Bool = true) -> ConversationMember {
        ConversationMember(
            profile: .mock(inboxId: inboxId, name: "Agent"),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: verified ? .verified(.convos) : .unverified
        )
    }

    private func groupWithAgent(id: String, agent: ConversationMember, isAgentDm: Bool = false) -> Conversation {
        var conversation = Conversation.mock(id: id, members: [.mock(isCurrentUser: true), agent])
        conversation.isAgentDm = isAgentDm
        return conversation
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("creates one DM per verified agent, keyed to the first origin conversation")
    func createsDmForVerifiedAgent() async throws {
        let recorder = Recorder()
        let agent = agentMember(inboxId: "agent-a")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: agent),
            groupWithAgent(id: "group-2", agent: agent),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: true,
            hasExistingDm: { _ in false },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return true
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        try await waitUntil { !recorder.calls.isEmpty }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.agent == "agent-a")
        #expect(recorder.calls.first?.origin == "group-1")
    }

    @Test("skips agents that already have a DM")
    func skipsExistingDm() async throws {
        let recorder = Recorder()
        let existing = Recorder()
        let agentA = agentMember(inboxId: "agent-a")
        let agentB = agentMember(inboxId: "agent-b")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: agentA),
            groupWithAgent(id: "group-2", agent: agentB),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: true,
            hasExistingDm: { agentInboxId in
                existing.record(agentInboxId, nil)
                return agentInboxId == "agent-a"
            },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return true
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        try await waitUntil { !recorder.calls.isEmpty }
        #expect(recorder.calls.map(\.agent) == ["agent-b"])
    }

    @Test("ignores unverified agents and the agent inside a DM conversation")
    func ignoresUnverifiedAndDmAgents() async throws {
        let recorder = Recorder()
        let unverified = agentMember(inboxId: "agent-unverified", verified: false)
        let dmAgent = agentMember(inboxId: "agent-in-dm")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: unverified),
            // The DM itself must not trigger a second DM with its own agent.
            groupWithAgent(id: "dm-1", agent: dmAgent, isAgentDm: true),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: true,
            hasExistingDm: { _ in false },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return true
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        // Give the reconcile pass time to run, then assert nothing was created.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.calls.isEmpty)
    }

    @Test("a failed creation is not retried on later emissions")
    func failureIsNotRetried() async throws {
        let recorder = Recorder()
        let agent = agentMember(inboxId: "agent-a")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: agent),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: true,
            hasExistingDm: { _ in false },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return false
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        try await waitUntil { !recorder.calls.isEmpty }
        // A database change re-emits the same conversations; the failed agent
        // must not be attempted again.
        subject.send([groupWithAgent(id: "group-1", agent: agent)])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.calls.count == 1)
    }

    @Test("a new agent appearing later still gets a DM after another agent failed")
    func laterAgentUnaffectedByEarlierFailure() async throws {
        let recorder = Recorder()
        let failing = agentMember(inboxId: "agent-failing")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: failing),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: true,
            hasExistingDm: { _ in false },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return agentInboxId != "agent-failing"
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        try await waitUntil { !recorder.calls.isEmpty }
        let late = agentMember(inboxId: "agent-late")
        subject.send([
            groupWithAgent(id: "group-1", agent: failing),
            groupWithAgent(id: "group-2", agent: late),
        ])
        try await waitUntil { recorder.calls.contains { $0.agent == "agent-late" } }
        #expect(recorder.calls.map(\.agent) == ["agent-failing", "agent-late"])
    }

    @Test("disabled reconciler never creates")
    func disabledDoesNothing() async throws {
        let recorder = Recorder()
        let agent = agentMember(inboxId: "agent-a")
        let subject = CurrentValueSubject<[Conversation], Never>([
            groupWithAgent(id: "group-1", agent: agent),
        ])
        let reconciler = AgentDmReconciler(
            conversationsPublisher: subject.eraseToAnyPublisher(),
            isEnabled: false,
            hasExistingDm: { _ in false },
            createDm: { agentInboxId, origin in
                recorder.record(agentInboxId, origin)
                return true
            }
        )
        reconciler.start()
        defer { reconciler.stop() }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.calls.isEmpty)
    }
}
