@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AgentTemplateRepository")
struct AgentTemplateRepositoryTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func makeRepository(
        database: DatabaseQueue,
        apiClient: any ConvosAPIClientProtocol
    ) -> AgentTemplateRepository {
        AgentTemplateRepository(
            apiClient: apiClient,
            databaseWriter: database,
            databaseReader: database,
            source: "test",
            clientDeviceIdProvider: { "test-device" },
            // No real waits between retry attempts: the retry tests assert on
            // attempt counts and keys, not timing, and real backoffs are what
            // let cooperative-pool starvation in the integration job push the
            // pipeline past waitForStatus budgets.
            backoffSleep: { _ in }
        )
    }

    /// Polls the persisted row until it reaches `target` or the timeout
    /// elapses; returns the latest row either way so assertions can inspect it.
    /// The pipeline runs in a detached `Task`, so the timeout is generous: these
    /// are fast in-memory tests, but they run in the integration job alongside
    /// the full (network-bound) suite, where the cooperative pool can starve the
    /// detached task for several seconds. It returns the instant `target` is
    /// reached, so the headroom only costs wall-time on a genuine failure.
    private func waitForStatus(
        _ target: DBAgentTemplateGeneration.Status,
        conversationId: String,
        in database: DatabaseQueue,
        timeout: TimeInterval = 20
    ) async throws -> DBAgentTemplateGeneration? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let row = try await database.read { db in
                try DBAgentTemplateGeneration
                    .filter(DBAgentTemplateGeneration.Columns.conversationId == conversationId)
                    .fetchOne(db)
            }
            if let row, row.statusValue == target { return row }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await database.read { db in
            try DBAgentTemplateGeneration
                .filter(DBAgentTemplateGeneration.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }

    @Test("Happy path: submit -> poll -> invite persists invited + templateId")
    func happyPath() async throws {
        let database = try makeDatabase()
        let api = HappyStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-1", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-1", in: database)
        #expect(row?.statusValue == .invited)
        #expect(row?.templateId != nil)
        #expect(api.joinedTemplateId == row?.templateId)
        #expect(api.joinedConversationId == "convo-1")
    }

    /// Anchored (`^...$`) and case-sensitive on purpose: the key becomes the
    /// assistant instance id, which is lowercase-only server-side, and
    /// `UUID().uuidString` is uppercase - a factory regression would produce
    /// mixed-case instance ids that break the server's lowercase assumption.
    private static let lowercaseV4UUIDPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    @Test("Minted join keys are lowercase v4 UUIDs")
    func joinKeyFactoryIsLowercaseV4() throws {
        for _ in 0..<256 {
            let key = ConvosAPI.JoinIdempotencyKey.mint().rawValue
            #expect(key.range(of: Self.lowercaseV4UUIDPattern, options: .regularExpression) != nil)
        }
    }

    @Test("Join key type rejects non-UUIDs and normalizes case on rehydrate")
    func joinKeyValidatesAndNormalizes() throws {
        #expect(ConvosAPI.JoinIdempotencyKey(rawValue: "not-a-uuid") == nil)
        #expect(ConvosAPI.JoinIdempotencyKey(rawValue: "") == nil)
        // An uppercase persisted value (e.g. a legacy or hand-edited row)
        // rehydrates to the lowercase wire form rather than passing through.
        let uppercase = "6F0F7A8E-1B2C-4D3E-8F4A-5B6C7D8E9F0A"
        let key = try #require(ConvosAPI.JoinIdempotencyKey(rawValue: uppercase))
        #expect(key.rawValue == uppercase.lowercased())
    }

    @Test("Join key is persisted lowercase and sent on the join request")
    func joinKeyPersistedAndSent() async throws {
        let database = try makeDatabase()
        let api = HappyStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-key", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-key", in: database)
        let persisted = try #require(row?.joinIdempotencyKey)
        #expect(persisted.range(of: Self.lowercaseV4UUIDPattern, options: .regularExpression) != nil)
        #expect(api.joinedIdempotencyKeys == [persisted])
    }

    @Test("Ambiguous join failure (timeout) reuses the persisted key on retry")
    func joinKeyReusedOnAmbiguousFailure() async throws {
        let database = try makeDatabase()
        let api = RetryJoinStubAPIClient(firstJoinError: URLError(.timedOut))
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-reuse", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-reuse", in: database)
        #expect(row?.statusValue == .invited)
        let keys = api.capturedJoinKeys
        #expect(keys.count == 2)
        let first = try #require(keys.first ?? nil)
        #expect(keys.last == first)
        #expect(row?.joinIdempotencyKey == first)
    }

    @Test("403 during invite retries with the same key (cold-launch auth-readiness race)")
    func joinKeyReusedOnForbidden() async throws {
        let database = try makeDatabase()
        let api = RetryJoinStubAPIClient(firstJoinError: APIError.forbidden)
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-403", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-403", in: database)
        #expect(row?.statusValue == .invited)
        let keys = api.capturedJoinKeys
        #expect(keys.count == 2)
        let first = try #require(keys.first ?? nil)
        #expect(keys.last == first)
        #expect(row?.joinIdempotencyKey == first)
    }

    @Test("Row cleared mid-invite stops the retry loop instead of re-joining")
    func rowClearedMidInviteStopsRetries() async throws {
        let database = try makeDatabase()
        let api = RowDeletingProvisionFailStubAPIClient(database: database)
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-cleared", slug: "chef.abcd")

        // The stub deletes the row inside the first join call and then throws
        // an explicit provision failure. The re-mint branch must notice the
        // missing row and stop; wait past the first backoff (1s) to catch a
        // would-be second attempt.
        let deadline = Date().addingTimeInterval(20)
        while api.joinCalls == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(api.joinCalls == 1)
        // Backoff is a no-op in tests, so a would-be retry fires immediately;
        // a short grace period is enough to catch it.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(api.joinCalls == 1)
        let row = try await database.read { db in
            try DBAgentTemplateGeneration
                .filter(DBAgentTemplateGeneration.Columns.conversationId == "convo-cleared")
                .fetchOne(db)
        }
        #expect(row == nil)
    }

    @Test("Explicit provision failure re-mints a fresh key for the retry")
    func joinKeyRemintedOnExplicitFailure() async throws {
        let database = try makeDatabase()
        let api = RetryJoinStubAPIClient(firstJoinError: APIError.agentProvisionFailed)
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "build me a chef", conversationId: "convo-remint", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-remint", in: database)
        #expect(row?.statusValue == .invited)
        let keys = api.capturedJoinKeys
        #expect(keys.count == 2)
        let first = try #require(keys.first ?? nil)
        let second = try #require(keys.last ?? nil)
        #expect(first != second)
        #expect(second.range(of: Self.lowercaseV4UUIDPattern, options: .regularExpression) != nil)
        // The replacement key is persisted so a relaunch resume retries with
        // it, not the corpse key.
        #expect(row?.joinIdempotencyKey == second)
    }

    @Test("Moderation rejection marks the row failed and never invites")
    func moderationFails() async throws {
        let database = try makeDatabase()
        let api = ModeratedStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        await repository.startGeneration(prompt: "disallowed", conversationId: "convo-2", slug: "x.y")

        let row = try await waitForStatus(.failed, conversationId: "convo-2", in: database)
        #expect(row?.statusValue == .failed)
        #expect(row?.errorMessage != nil)
        #expect(api.joinCalls == 0)
    }

    @Test("Attachment upload failure marks the row failed and never submits")
    func attachmentUploadFails() async throws {
        let database = try makeDatabase()
        let api = AttachmentUploadFailingStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        let attachment = AgentBuildAttachmentInput(
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/jpeg",
            filename: nil
        )
        await repository.startGeneration(
            prompt: "build me a chef",
            conversationId: "convo-3",
            slug: "chef.abcd",
            attachments: [attachment],
            connections: [],
            variantId: nil
        )

        let row = try await waitForStatus(.failed, conversationId: "convo-3", in: database)
        #expect(row?.statusValue == .failed)
        #expect(row?.errorMessage != nil)
        // The pipeline must terminate at the failed upload: the generation
        // submit and the agent-join are never reached (regression guard for
        // `uploadAttachments` returning the failed row instead of nil, which
        // let `submit` clobber the failure and build without attachments).
        #expect(api.generationCalls == 0)
        #expect(api.joinCalls == 0)
    }

    @Test("Generation 401/403 map to terminal badRequest, 5xx stays retryable server")
    func generationAuthFailuresAreTerminal() throws {
        // A surfaced 401/403 already exhausted the auth refresh inside
        // performAuthenticatedRequest, so a plain retry can't heal it. Mapping
        // it to the retryable `.server` case made the builder retry silently
        // and then fail with a generic "Couldn't reach the builder".
        let api = try #require(ConvosAPIClientFactory.client(
            environment: .local(config: ConvosConfiguration(
                apiBaseURL: "https://api.example.com",
                appGroupIdentifier: "group.test",
                relyingPartyIdentifier: "example.com",
                siweConfiguration: SIWEConfiguration(domain: "example.com", uri: "https://example.com", chainId: 1)
            ))
        ) as? ConvosAPIClient)
        func decode(status: Int, body: String = #"{"error":"Account required"}"#) throws -> ConvosAPI.AgentTemplateGenerationResponse {
            let url = try #require(URL(string: "https://api.example.com/api/v2/agent-templates/generations"))
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return try api.decodeGenerationResponse(data: Data(body.utf8), httpResponse: response)
        }

        for status in [401, 403] {
            #expect(throws: AgentGenerationError.self) { try decode(status: status) }
            do {
                _ = try decode(status: status)
            } catch let error as AgentGenerationError {
                guard case .badRequest(let message) = error else {
                    Issue.record("Expected .badRequest for \(status), got \(error)")
                    return
                }
                #expect(message == "Account required")
            }
        }

        do {
            _ = try decode(status: 500)
        } catch let error as AgentGenerationError {
            guard case .server = error else {
                Issue.record("Expected .server for 500, got \(error)")
                return
            }
        }
    }
}

/// Submit returns pending, the first poll returns done, and the join records
/// what it was asked to invite.
private final class HappyStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private let templateId: String = UUID().uuidString
    private var capturedTemplateId: String?
    private var capturedConversationId: String?
    private var capturedIdempotencyKeys: [String?] = []

    var joinedTemplateId: String? { lock.withLock { capturedTemplateId } }
    var joinedConversationId: String? { lock.withLock { capturedConversationId } }
    var joinedIdempotencyKeys: [String?] { lock.withLock { capturedIdempotencyKeys } }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: "gen-1",
            status: .pending,
            templateId: nil,
            error: nil
        )
    }

    override func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: generationId,
            status: .done,
            templateId: templateId,
            error: nil
        )
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock {
            capturedTemplateId = joinRequest.templateId
            capturedConversationId = joinRequest.conversationId
            capturedIdempotencyKeys.append(joinRequest.idempotencyKey?.rawValue)
        }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}

/// Submit is rejected by moderation; the join must never be reached.
private final class ModeratedStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private var joinCallCount: Int = 0

    var joinCalls: Int { lock.withLock { joinCallCount } }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        throw AgentGenerationError.moderationBlocked("not allowed")
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock { joinCallCount += 1 }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}

/// The attachment presigned-URL request fails, so the pipeline must mark the
/// row failed and never reach submit or join.
private final class AttachmentUploadFailingStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private var generationCallCount: Int = 0
    private var joinCallCount: Int = 0

    var generationCalls: Int { lock.withLock { generationCallCount } }
    var joinCalls: Int { lock.withLock { joinCallCount } }

    override func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String) {
        throw APIError.invalidRequest
    }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        lock.withLock { generationCallCount += 1 }
        return ConvosAPI.AgentTemplateGenerationResponse(
            generationId: "gen-x",
            status: .pending,
            templateId: nil,
            error: nil
        )
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock { joinCallCount += 1 }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}

/// Deletes the generation row (simulating `clearGeneration` racing the
/// pipeline) inside the join call, then throws an explicit provision failure.
/// The invite's re-mint branch must detect the missing row and stop instead
/// of retrying a build that no longer exists.
private final class RowDeletingProvisionFailStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private let templateId: String = UUID().uuidString
    private let database: DatabaseQueue
    private var joinCallCount: Int = 0

    var joinCalls: Int { lock.withLock { joinCallCount } }

    init(database: DatabaseQueue) {
        self.database = database
    }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: "gen-cleared",
            status: .pending,
            templateId: nil,
            error: nil
        )
    }

    override func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: generationId,
            status: .done,
            templateId: templateId,
            error: nil
        )
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock { joinCallCount += 1 }
        _ = try? await database.write { db in
            try DBAgentTemplateGeneration.deleteAll(db)
        }
        throw APIError.agentProvisionFailed
    }
}

/// The first join attempt throws `firstJoinError`; the second succeeds.
/// Parameterized by the error so both halves of the join-key policy are
/// testable: ambiguous transport failures reuse the persisted key, explicit
/// provision failures re-mint a fresh one.
private final class RetryJoinStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private let templateId: String = UUID().uuidString
    private let firstJoinError: Error
    private var joinKeys: [String?] = []

    var capturedJoinKeys: [String?] { lock.withLock { joinKeys } }

    init(firstJoinError: Error) {
        self.firstJoinError = firstJoinError
    }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: "gen-retry",
            status: .pending,
            templateId: nil,
            error: nil
        )
    }

    override func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: generationId,
            status: .done,
            templateId: templateId,
            error: nil
        )
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        let shouldThrow: Bool = lock.withLock {
            joinKeys.append(joinRequest.idempotencyKey?.rawValue)
            return joinKeys.count == 1
        }
        if shouldThrow { throw firstJoinError }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}
