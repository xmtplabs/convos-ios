@testable import ConvosCore
import Foundation
import Testing

@Suite("AgentRelay client")
struct AgentRelayClientTests {
    @Test("send persists pending, completed, and acked in order")
    func sendOrdersDurableSaveBeforeAck() async throws {
        let recorder = AgentRelayCallRecorder()
        let result = makeAgentRelayResult()
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], recorder: recorder)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(recorder: recorder),
            store: RecordingAgentChatWriter(recorder: recorder, provider: .town),
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.send(prompt: "Prompt", connection: makeAgentConnection())

        #expect(outcome == .completed(result))
        #expect(recorder.calls == ["mint", "pending", "webhook", "fetch", "completed", "ack", "acked"])
    }

    @Test("watch persists a completion with the pending turn provider")
    func watchUsesStoredProviderForCompletion() async throws {
        let recorder = AgentRelayCallRecorder()
        let result = makeAgentRelayResult()
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], recorder: recorder)
        let writer = RecordingAgentChatWriter(recorder: recorder, provider: .tasklet)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.watch(requestId: "request_tasklet")

        #expect(outcome == .completed(result))
        #expect(writer.completedProviders == [.tasklet])
        #expect(api.ackCount == 1)
    }

    @Test("watch leaves an unattributable completion in the mailbox")
    func watchWithoutProviderDoesNotPersistOrAck() async throws {
        let recorder = AgentRelayCallRecorder()
        let result = makeAgentRelayResult()
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], recorder: recorder)
        let writer = RecordingAgentChatWriter(recorder: recorder)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.watch(requestId: "request_unattributed")

        #expect(outcome == .stillWorking)
        #expect(writer.completedProviders.isEmpty)
        #expect(api.ackCount == 0)
        #expect(recorder.calls == ["fetch"])
    }

    @Test("send derives one provider from the connection")
    func sendUsesConnectionProviderThroughoutTriggerSetup() async throws {
        let recorder = AgentRelayCallRecorder()
        let api = ScriptedAgentRelayAPI(recorder: recorder)
        let webhook = ScriptedWebhookTransport(
            error: AgentWebhookTransportError.rejected(status: 401),
            recorder: recorder
        )
        let writer = RecordingAgentChatWriter(recorder: recorder)
        let client = AgentRelayClient(
            api: api,
            webhook: webhook,
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.send(prompt: "Prompt", connection: makeAgentConnection(provider: .tasklet))

        #expect(outcome == .failed(.webhookRejected(provider: .tasklet, status: 401)))
        #expect(api.mintProviders == [.tasklet])
        #expect(writer.pendingProviders == [.tasklet])
        #expect(webhook.auths == [.capabilityURL])
        #expect(recorder.calls == ["mint", "pending", "webhook", "failed"])
    }

    @Test("webhook rejection marks the row failed and never polls")
    func webhookRejectionStopsBeforePoll() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let api = ScriptedAgentRelayAPI()
        let webhook = ScriptedWebhookTransport(error: AgentWebhookTransportError.rejected(status: 401))
        let client = AgentRelayClient(api: api, webhook: webhook, store: writer, history: StubAgentHistoryBuilder())

        let outcome = try await client.send(prompt: "Prompt", connection: makeAgentConnection())
        let turn = try repository.turn(requestId: "request_test")

        #expect(outcome == .failed(.webhookRejected(provider: .town, status: 401)))
        #expect(turn?.status == .failed)
        #expect(turn?.errorCode == "webhookRejected:town:401")
        #expect(api.fetchCount == 0)
    }

    @Test("pending polls reissue until one completed row is saved")
    func pollingReissuesPendingResponses() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "Finished")
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [
            .pending(expiresAt: Date().addingTimeInterval(3_600)),
            .pending(expiresAt: Date().addingTimeInterval(3_600)),
            .completed(result),
        ])
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        _ = try await client.send(prompt: "Prompt", connection: makeAgentConnection())

        let turns = try repository.turns(limit: 10)
        #expect(api.fetchCount == 3)
        #expect(turns.count == 1)
        #expect(turns.first?.status == .completed)
        #expect(turns.first?.ackedAt != nil)
    }

    @Test("polling caps its wait at the deadline and performs a final instant check")
    func pollingCapsWaitAtDeadline() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let clock = ScriptedDateProvider(dates: [
            startedAt,
            startedAt.addingTimeInterval(595),
            startedAt.addingTimeInterval(600),
        ])
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [
            .pending(expiresAt: startedAt.addingTimeInterval(3_600)),
            .pending(expiresAt: startedAt.addingTimeInterval(3_600)),
        ])
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: RecordingAgentChatWriter(recorder: AgentRelayCallRecorder()),
            history: StubAgentHistoryBuilder(),
            now: { clock.now() }
        )

        let outcome = try await client.watch(requestId: "request_deadline")

        #expect(outcome == .stillWorking)
        #expect(api.fetchWaitMilliseconds == [5_000, 0])
    }

    @Test("watch retries transient fetch failures and completes")
    func watchRetriesTransientFailures() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "Recovered after retries")
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)])
        api.failNextFetches(with: [AgentRelayError.relayUnreachable, AgentRelayError.relayUnreachable])
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder(),
            sleep: { _ in }
        )

        let outcome = try await client.send(prompt: "Prompt", connection: makeAgentConnection())
        let turn = try repository.turn(requestId: "request_test")

        #expect(outcome == .completed(result))
        #expect(api.fetchCount == 3)
        #expect(turn?.status == .completed)
        #expect(turn?.ackedAt != nil)
    }

    @Test("watch stops retrying transient failures at its deadline")
    func watchStopsRetryingAtDeadline() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let clock = MutableAgentRelayClock(now: Date(timeIntervalSince1970: 1_000))
        try writer.insertPending(makeAgentTurn(requestId: "request_deadline"))
        let api = ScriptedAgentRelayAPI()
        api.failEveryFetch(with: AgentRelayError.relayUnreachable)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder(),
            sleep: { delay in clock.advance(by: delay) },
            now: { clock.current }
        )

        let outcome = try await client.watch(requestId: "request_deadline")

        #expect(outcome == .stillWorking)
        #expect(api.fetchCount > 1)
        #expect(clock.current.timeIntervalSince1970 == 1_600)
    }

    @Test("watch completes a Tasklet turn with its journaled provider")
    func watchUsesJournaledTaskletProvider() async throws {
        let recorder = AgentRelayCallRecorder()
        let writer = RecordingAgentChatWriter(recorder: recorder, provider: .tasklet)
        let result = makeAgentRelayResult(message: "Tasklet result")
        let client = AgentRelayClient(
            api: ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)]),
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.watch(requestId: "request_tasklet")

        #expect(outcome == .completed(result))
        #expect(writer.completedProviders == [.tasklet])
    }

    @Test("expired fetch marks a pending row expired")
    func expiredFetchMarksTurnExpired() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_expired"))
        let client = AgentRelayClient(
            api: ScriptedAgentRelayAPI(fetchOutcomes: [.expired]),
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.watch(requestId: "request_expired")

        #expect(outcome == .expired)
        #expect(try repository.turn(requestId: "request_expired")?.status == .expired)
    }

    @Test("not found fetch marks a pending row collected elsewhere")
    func notFoundFetchMarksCollectedElsewhere() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_elsewhere"))
        let client = AgentRelayClient(
            api: ScriptedAgentRelayAPI(fetchOutcomes: [.notFound]),
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let outcome = try await client.watch(requestId: "request_elsewhere")

        #expect(outcome == .collectedElsewhere)
        #expect(try repository.turn(requestId: "request_elsewhere")?.status == .collectedElsewhere)
    }

    @Test("cancelling a poll leaves its row pending and does not ack")
    func cancellationLeavesPendingRow() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_cancel"))
        let api = ScriptedAgentRelayAPI(blocksFetch: true)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let task = Task {
            try await client.watch(requestId: "request_cancel")
        }
        while api.fetchCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try repository.turn(requestId: "request_cancel")?.status == .pending)
        #expect(api.ackCount == 0)
    }

    @Test("ack failure leaves a durable completed row and recovery acks it")
    func crashBetweenSaveAndAckRecovers() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "Durable")
        try writer.insertPending(makeAgentTurn(requestId: "request_crash"))
        let entry = AgentRelayCompletedEntry(requestId: "request_crash", provider: .town, result: result)
        let api = ScriptedAgentRelayAPI(
            fetchOutcomes: [.completed(result)],
            completedEntries: [entry],
            ackFailuresRemaining: 1
        )
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        await #expect(throws: AgentRelayTestError.self) {
            try await client.watch(requestId: "request_crash")
        }
        let afterFailure = try repository.turn(requestId: "request_crash")
        #expect(afterFailure?.status == .completed)
        #expect(afterFailure?.ackedAt == nil)

        let recovery = AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer)
        await recovery.runOnLaunch()
        let afterRecovery = try repository.turn(requestId: "request_crash")
        #expect(afterRecovery?.status == .completed)
        #expect(afterRecovery?.ackedAt != nil)
        #expect(try repository.turns(limit: 10).count == 1)
        #expect(api.ackCount == 2)
    }

    @Test("recovery collects a listed result for a local pending row")
    func recoveryCollectsLocalPendingEntry() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "Recovered")
        try writer.insertPending(makeAgentTurn(requestId: "request_recover"))
        let entry = AgentRelayCompletedEntry(requestId: "request_recover", provider: .town, result: result)
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], completedEntries: [entry])
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        await AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer).runOnLaunch()

        let turn = try repository.turn(requestId: "request_recover")
        #expect(turn?.status == .completed)
        #expect(turn?.ackedAt != nil)
        #expect(api.ackCount == 1)
    }

    @Test("recovery collects and persists listed entries without a local row")
    func recoveryCollectsUnknownEntryAndInserts() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "Recovered from mailbox")
        let entry = AgentRelayCompletedEntry(requestId: "request_unknown", provider: .tasklet, result: result)
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], completedEntries: [entry])
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        await AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer).runOnLaunch()

        let turn = try repository.turn(requestId: "request_unknown")
        #expect(turn?.status == .completed)
        #expect(turn?.provider == .tasklet)
        #expect(turn?.resultMessage == "Recovered from mailbox")
        #expect(turn?.ackedAt != nil)
        #expect(api.ackCount == 1)
        #expect(api.fetchCount == 1)
    }

    @Test("recovery is a no-op when completed listing fails")
    func recoveryListingFailureDoesNotMutateLocalState() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let repository = AgentChatRepository(database: database)
        let setupWriter = AgentChatWriter(database: database)
        try setupWriter.insertPending(makeAgentTurn(requestId: "request_stale", expiresAt: Date().addingTimeInterval(-1)))
        let recorder = AgentRelayCallRecorder()
        let writer = RecordingAgentChatWriter(recorder: recorder)
        let api = ScriptedAgentRelayAPI(listCompletedError: AgentRelayTestError.expected)
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        await AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer).runOnLaunch()

        #expect(recorder.calls.isEmpty)
        #expect(api.fetchCount == 0)
        #expect(api.ackCount == 0)
        #expect(try repository.turn(requestId: "request_stale")?.status == .pending)
    }

    @Test("recovery replaces an expired row with a listed completion")
    func recoveryReconcilesExpiredEntry() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_expired_recovery", status: .expired))
        let result = makeAgentRelayResult(message: "Real completion")
        let entry = AgentRelayCompletedEntry(requestId: "request_expired_recovery", provider: .tasklet, result: result)
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], completedEntries: [entry])
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        await AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer).runOnLaunch()

        let turn = try repository.turn(requestId: "request_expired_recovery")
        #expect(turn?.status == .completed)
        #expect(turn?.provider == .town)
        #expect(turn?.resultMessage == "Real completion")
        #expect(turn?.errorCode == nil)
        #expect(turn?.ackedAt != nil)
        #expect(api.ackCount == 1)
    }

    @Test("recovery expires stale pending rows absent from the listing")
    func recoveryExpiresStalePendingTurn() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_stale", expiresAt: Date().addingTimeInterval(-1)))
        let client = AgentRelayClient(
            api: ScriptedAgentRelayAPI(),
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        await AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer).runOnForeground()

        #expect(try repository.turn(requestId: "request_stale")?.status == .expired)
    }

    @Test("failed recovery listing changes nothing and the next pass recovers")
    func failedRecoveryListingRetriesCleanly() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let listedResult = makeAgentRelayResult(message: "Listed result")
        let resumedResult = makeAgentRelayResult(message: "Resumed result")
        let listedRequestId = "request_listed_after_auth"
        let resumedRequestId = "request_resumed_after_auth"
        let staleRequestId = "request_stale_after_auth"
        try writer.insertPending(makeAgentTurn(requestId: listedRequestId))
        try writer.insertPending(makeAgentTurn(requestId: resumedRequestId))
        try writer.insertPending(makeAgentTurn(
            requestId: staleRequestId,
            expiresAt: Date().addingTimeInterval(-1)
        ))
        let entry = AgentRelayCompletedEntry(
            requestId: listedRequestId,
            provider: .town,
            result: listedResult
        )
        let api = ScriptedAgentRelayAPI(
            fetchOutcomes: [.completed(listedResult), .completed(resumedResult)],
            completedEntries: [entry]
        )
        api.failNextCompletedListings(with: [AgentRelayError.relayRejected(403)])
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )
        let recovery = AgentRelayRecoveryCoordinator(client: client, repository: repository, writer: writer)

        await recovery.runOnLaunch()

        #expect(try repository.turn(requestId: listedRequestId)?.status == .pending)
        #expect(try repository.turn(requestId: resumedRequestId)?.status == .pending)
        #expect(try repository.turn(requestId: staleRequestId)?.status == .pending)
        #expect(api.fetchCount == 0)
        #expect(api.ackCount == 0)

        await recovery.runOnForeground()
        while api.ackCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(try repository.turn(requestId: listedRequestId)?.status == .completed)
        #expect(try repository.turn(requestId: listedRequestId)?.ackedAt != nil)
        #expect(try repository.turn(requestId: resumedRequestId)?.status == .completed)
        #expect(try repository.turn(requestId: resumedRequestId)?.ackedAt != nil)
        #expect(try repository.turn(requestId: staleRequestId)?.status == .expired)
        #expect(api.fetchCount == 2)
        #expect(api.ackCount == 2)
    }

    @Test("collect inserts another-device result and acks once")
    func collectInsertsMissingCompletedRow() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let result = makeAgentRelayResult(message: "From another phone")
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)])
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        let collected = try await client.collect(requestId: "request_remote", provider: .tasklet)

        let turn = try repository.turn(requestId: "request_remote")
        #expect(collected == result)
        #expect(turn?.prompt == "(completed on another device)")
        #expect(turn?.provider == .tasklet)
        #expect(turn?.ackedAt != nil)
        #expect(api.ackCount == 1)
    }

    @Test("collect leaves an unattributable completion in the mailbox")
    func collectWithoutAnyProviderDoesNotPersistOrAck() async throws {
        let recorder = AgentRelayCallRecorder()
        let result = makeAgentRelayResult(message: "Needs provider")
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.completed(result)], recorder: recorder)
        let writer = RecordingAgentChatWriter(recorder: recorder)
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let collected = try await client.collect(requestId: "request_unattributed", provider: nil)

        #expect(collected == nil)
        #expect(writer.completedProviders.isEmpty)
        #expect(api.ackCount == 0)
        #expect(recorder.calls == ["fetch"])
    }

    @Test("collect on not found returns nil without inserting")
    func collectNotFoundDoesNothing() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.notFound])
        let client = AgentRelayClient(api: api, webhook: ScriptedWebhookTransport(), store: writer, history: StubAgentHistoryBuilder())

        let collected = try await client.collect(requestId: "request_missing", provider: .town)

        #expect(collected == nil)
        #expect(try repository.turns(limit: 10).isEmpty)
        #expect(api.ackCount == 0)
    }

    @Test("collect on not found marks a local pending row collected elsewhere")
    func collectNotFoundMarksPendingRowCollectedElsewhere() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_collect_elsewhere", provider: .tasklet))
        let api = ScriptedAgentRelayAPI(fetchOutcomes: [.notFound])
        let client = AgentRelayClient(
            api: api,
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        let collected = try await client.collect(requestId: "request_collect_elsewhere", provider: .tasklet)

        #expect(collected == nil)
        #expect(try repository.turn(requestId: "request_collect_elsewhere")?.status == .collectedElsewhere)
        #expect(api.ackCount == 0)
    }

    @Test("not found fetch marks a past-expiry pending row expired")
    func notFoundFetchMarksPastExpiryTurnExpired() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(
            requestId: "request_past_expiry",
            expiresAt: Date().addingTimeInterval(-60)
        ))
        let client = AgentRelayClient(
            api: ScriptedAgentRelayAPI(fetchOutcomes: [.notFound]),
            webhook: ScriptedWebhookTransport(),
            store: writer,
            history: StubAgentHistoryBuilder()
        )

        _ = try await client.watch(requestId: "request_past_expiry")

        #expect(try repository.turn(requestId: "request_past_expiry")?.status == .expired)
    }
}
