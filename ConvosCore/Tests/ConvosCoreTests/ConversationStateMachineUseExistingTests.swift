@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing

private let testEnvironment = AppEnvironment.tests

/// Tests for `ConversationStateMachine.useExisting(conversationId:)`. Each
/// test creates a real conversation with one state machine, then drives a
/// fresh state machine through `useExisting` on the same id and asserts the
/// resume semantics (origin, message sending, state sequence, post-stop
/// recovery).
@Suite("ConversationStateMachine UseExisting Flow", .serialized, .timeLimit(.minutes(3)))
struct ConversationStateMachineUseExistingTests {
    @Test("UseExisting transitions to ready state with existing origin")
    func testUseExistingFlow() async throws {
        let fixtures = TestFixtures()

        let messagingService = fixtures.makeFreshMessagingService()

        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        let initialState = await stateMachine.state
        #expect(initialState == .uninitialized)

        await stateMachine.useExisting(conversationId: conversationId)

        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    switch state {
                    case .ready(let readyResult):
                        return readyResult
                    case .error(let error):
                        throw error
                    default:
                        continue
                    }
                }
                return nil
            }
        } catch {
            Issue.record("UseExisting timed out or failed: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        #expect(result != nil, "Should reach ready state")
        #expect(result?.origin == .existing, "Origin should be existing")
        #expect(result?.conversationId == conversationId, "Should have correct conversation ID")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting allows sending messages immediately")
    func testUseExistingWithMessages() async throws {
        let fixtures = TestFixtures()

        let messagingService = fixtures.makeFreshMessagingService()

        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await stateMachine.useExisting(conversationId: conversationId)

        do {
            _ = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("UseExisting timed out: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        await stateMachine.sendMessage(text: "Message via useExisting 1")
        await stateMachine.sendMessage(text: "Message via useExisting 2")

        try await waitForMessages(
            conversationId: conversationId,
            expectedCount: 2,
            databaseReader: fixtures.databaseManager.dbReader
        )

        let messages = try await fixtures.databaseManager.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchAll(db)
        }
        #expect(messages.count >= 2, "Messages should be sent via useExisting")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting emits correct state sequence")
    func testUseExistingStateSequence() async throws {
        let fixtures = TestFixtures()

        let messagingService = fixtures.makeFreshMessagingService()

        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        actor StateCollector {
            var states: [String] = []
            func add(_ state: String) {
                states.append(state)
            }
            func getStates() -> [String] {
                states
            }
        }

        let collector = StateCollector()

        let observerTask = Task {
            for await state in await stateMachine.stateSequence {
                let stateName: String
                switch state {
                case .uninitialized:
                    stateName = "uninitialized"
                case .ready(let result) where result.origin == .existing:
                    stateName = "ready_existing"
                case .ready:
                    stateName = "ready"
                case .error:
                    stateName = "error"
                default:
                    stateName = "other"
                }
                await collector.add(stateName)

                if stateName == "ready_existing" || stateName == "error" {
                    break
                }
            }
        }

        await stateMachine.useExisting(conversationId: conversationId)

        await observerTask.value

        let observedStates = await collector.getStates()
        #expect(observedStates.contains("ready_existing"), "Should reach ready with existing origin")
        #expect(!observedStates.contains("other"), "Should not have intermediate states")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting can be called after stop")
    func testUseExistingAfterStop() async throws {
        let fixtures = TestFixtures()

        let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId(),
            coreActions: NoOpCoreActions()
        )

        await stateMachine.create()

        var conversationId: String?
        do {
            conversationId = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let convId = conversationId else {
            Issue.record("No conversation ID")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        await stateMachine.stop()

        do {
            _ = try await withTimeout(seconds: 10) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Timed out waiting for uninitialized: \(error)")
        }

        await stateMachine.useExisting(conversationId: convId)

        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 5) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let readyResult) = state {
                        return readyResult
                    }
                }
                throw UseExistingTestError.timeout("Never reached ready state")
            }
        } catch {
            Issue.record("UseExisting after stop failed: \(error)")
        }

        #expect(result != nil, "Should reach ready state after stop + useExisting")
        #expect(result?.origin == .existing, "Origin should be existing")
        #expect(result?.conversationId == convId, "Should have same conversation ID")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }
}

// MARK: - Helpers

private enum UseExistingTestError: Error {
    case timeout(String)
}

private func waitForMessages(
    conversationId: String,
    expectedCount: Int,
    databaseReader: any DatabaseReader,
    timeout: Duration = .seconds(10)
) async throws {
    let deadline = ContinuousClock.now + timeout

    while ContinuousClock.now < deadline {
        let messageCount = try await databaseReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchCount(db)
        }

        if messageCount >= expectedCount {
            return
        }

        try await Task.sleep(for: .milliseconds(100))
    }

    throw UseExistingTestError.timeout("Timed out waiting for \(expectedCount) messages to be saved")
}
