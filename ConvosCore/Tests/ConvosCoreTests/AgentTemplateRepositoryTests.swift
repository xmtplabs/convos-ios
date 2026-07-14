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
            clientDeviceIdProvider: { "test-device" }
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

        repository.startGeneration(prompt: "build me a chef", conversationId: "convo-1", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-1", in: database)
        #expect(row?.statusValue == .invited)
        #expect(row?.templateId != nil)
        #expect(api.joinedTemplateId == row?.templateId)
        #expect(api.joinedConversationId == "convo-1")
    }

    @Test("Moderation rejection marks the row failed and never invites")
    func moderationFails() async throws {
        let database = try makeDatabase()
        let api = ModeratedStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        repository.startGeneration(prompt: "disallowed", conversationId: "convo-2", slug: "x.y")

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
        repository.startGeneration(
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

    var joinedTemplateId: String? { lock.withLock { capturedTemplateId } }
    var joinedConversationId: String? { lock.withLock { capturedConversationId } }

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
        slug: String?,
        conversationId: String?,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        timezone: String?,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock {
            capturedTemplateId = templateId
            capturedConversationId = conversationId
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
        slug: String?,
        conversationId: String?,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        timezone: String?,
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
        slug: String?,
        conversationId: String?,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        timezone: String?,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock { joinCallCount += 1 }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}
