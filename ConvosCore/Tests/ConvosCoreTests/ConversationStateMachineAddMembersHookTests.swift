@preconcurrency @testable import ConvosCore
import Foundation
import Testing

private let testEnvironment = AppEnvironment.tests

/// Covers the addMembers hook that `ConversationStateMachine.handleCreate`
/// and `handleUseExisting` run between conversation publish/resume and the
/// `.ready` transition. The contacts picker flow wires this to
/// `ConversationMetadataWriter.addMembers(_:to:)` so that `.ready` is the
/// strong guarantee "conversation exists and its initial members are in it".
@Suite("ConversationStateMachine addMembers hook", .serialized, .timeLimit(.minutes(3)))
struct ConversationStateMachineAddMembersHookTests {
    @Test("create() with initial members invokes addMembers hook before reaching ready")
    func testCreateInvokesAddMembersHookBeforeReady() async throws {
        let fixtures = TestFixtures()
        let messagingService = fixtures.makeFreshMessagingService()

        let collector = HookInvocationCollector()
        let observedReadyAtHookTime = ReadyStateProbe()

        let probedHook: ConversationStateMachineAddMembersHook = { ids, convId in
            // Capture the current state of the probe at the moment the
            // hook fires. If `.ready` has already been emitted, the probe
            // returns true, which would mean the state machine reached
            // `.ready` before adding members (the regression we're guarding).
            await observedReadyAtHookTime.snapshot()
            await collector.record(ids: ids, conversationId: convId)
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            addMembersHook: probedHook
        )

        let probeWatcher = Task {
            for await state in await stateMachine.stateSequence {
                if case .ready = state {
                    await observedReadyAtHookTime.markReady()
                    return
                }
            }
        }

        let initialMembers = ["test-inbox-id-alice", "test-inbox-id-bob"]
        await stateMachine.create(initialMemberInboxIds: initialMembers)

        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 30) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let readyResult) = state {
                        return readyResult
                    }
                    if case .error(let error) = state {
                        Issue.record("Unexpected error: \(error)")
                        return nil
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for ready: \(error)")
        }

        _ = await probeWatcher.value

        #expect(result != nil, "Should reach ready state")
        let invocations = await collector.invocations
        #expect(invocations.count == 1, "Hook should have been invoked exactly once")
        #expect(invocations.first?.ids == initialMembers, "Hook should receive the supplied inbox IDs")
        #expect(invocations.first?.conversationId == result?.conversationId,
                "Hook should be called with the published conversation id")
        let readyAtHookTime = await observedReadyAtHookTime.wasReadyWhenHookFired
        #expect(readyAtHookTime == false, "Hook must fire before .ready transitions")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("create() with empty initial members does not invoke addMembers hook")
    func testCreateWithEmptyInitialMembersSkipsHook() async throws {
        let fixtures = TestFixtures()
        let messagingService = fixtures.makeFreshMessagingService()

        let collector = HookInvocationCollector()
        let hook: ConversationStateMachineAddMembersHook = { ids, convId in
            await collector.record(ids: ids, conversationId: convId)
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            addMembersHook: hook
        )

        await stateMachine.create()

        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 30) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let readyResult) = state {
                        return readyResult
                    }
                    if case .error(let error) = state {
                        Issue.record("Unexpected error: \(error)")
                        return nil
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for ready: \(error)")
        }

        #expect(result != nil, "Should reach ready state")
        let invocations = await collector.invocations
        #expect(invocations.isEmpty, "Hook must not be called when no initial members are supplied")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("create() with failing addMembers hook transitions to error(addMembersFailed)")
    func testCreateWhenAddMembersHookFailsTransitionsToError() async throws {
        let fixtures = TestFixtures()
        let messagingService = fixtures.makeFreshMessagingService()

        struct AddMembersTestError: Error, Equatable {}
        let failingHook: ConversationStateMachineAddMembersHook = { _, _ in
            throw AddMembersTestError()
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            addMembersHook: failingHook
        )

        await stateMachine.create(initialMemberInboxIds: ["test-inbox-id-alice"])

        var observedError: ConversationStateMachineError?
        do {
            observedError = try await withTimeout(seconds: 30) {
                for await state in await stateMachine.stateSequence {
                    if case .error(let error) = state {
                        return error as? ConversationStateMachineError
                    }
                    if case .ready = state {
                        Issue.record("Should not reach .ready when addMembers hook fails")
                        return nil
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for error state: \(error)")
        }

        #expect(observedError != nil, "Should transition to error state")
        guard let observed = observedError else {
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }
        if case .addMembersFailed(let underlying) = observed {
            #expect(underlying is AddMembersTestError,
                    "addMembersFailed should wrap the underlying hook error")
        } else {
            Issue.record("Expected .addMembersFailed, got \(observed)")
        }

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }
}

// MARK: - Helpers

private actor HookInvocationCollector {
    struct Invocation: Equatable {
        let ids: [String]
        let conversationId: String
    }

    private(set) var invocations: [Invocation] = []

    func record(ids: [String], conversationId: String) {
        invocations.append(Invocation(ids: ids, conversationId: conversationId))
    }
}

private actor ReadyStateProbe {
    private var ready: Bool = false
    private(set) var wasReadyWhenHookFired: Bool = false

    func markReady() {
        ready = true
    }

    func snapshot() {
        wasReadyWhenHookFired = ready
    }
}
