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
            connections: []
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

    /// Regression: backgrounding the app mid-join (the inbox-poll is
    /// interrupted, so the first attempt throws a retryable error even though
    /// the agent really was provisioned on the backend) must resume the same
    /// instance on retry rather than provisioning a second agent. Before the
    /// fix the invite step re-provisioned on every attempt, so a build that was
    /// backgrounded during the join phase produced two (or more) back-to-back
    /// agents with the same name -- the first stuck retrying `herald-attach`,
    /// the later one succeeding.
    @Test("Interrupted join resumes the persisted instance instead of provisioning a duplicate")
    func interruptedJoinResumesInstance() async throws {
        let database = try makeDatabase()
        let api = HappyStubAPIClient()
        let repository = makeRepository(database: database, apiClient: api)

        let recorder = ProvisionRecorder()
        repository.configureJoinHandler { _, _, existingInstanceId, writeInstanceId in
            // Resume path: a prior attempt already provisioned this instance, so
            // no new agent is created -- the poll + add just complete.
            if let existingInstanceId {
                await writeInstanceId(existingInstanceId)
                return
            }
            // Fresh provision. Persist the instance id the moment it is known,
            // then simulate the app being backgrounded during the inbox-poll on
            // the first attempt: the instance exists on the backend, but this
            // attempt sees a retryable timeout.
            let instanceId = recorder.provision()
            await writeInstanceId(instanceId)
            if recorder.provisionCount == 1 {
                throw APIError.agentPoolTimeout
            }
        }

        repository.startGeneration(prompt: "build me a chef", conversationId: "convo-4", slug: "chef.abcd")

        let row = try await waitForStatus(.invited, conversationId: "convo-4", in: database)
        #expect(row?.statusValue == .invited)
        // Provisioned exactly once: the retry resumed the persisted instance
        // rather than creating a second agent.
        #expect(recorder.provisionCount == 1)
        #expect(row?.agentInstanceId == "instance-1")
    }
}

/// Thread-safe counter standing in for backend agent provisioning: each
/// `provision()` mints a new instance id and bumps the count, so a test can
/// assert an interrupted-then-resumed join only provisions once.
private final class ProvisionRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var count: Int = 0

    var provisionCount: Int { lock.withLock { count } }

    func provision() -> String {
        lock.withLock {
            count += 1
            return "instance-\(count)"
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
        text: String,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        attachments: [ConvosAPI.AttachmentRef],
        connections: [String]
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
        text: String,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        attachments: [ConvosAPI.AttachmentRef],
        connections: [String]
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
        text: String,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        attachments: [ConvosAPI.AttachmentRef],
        connections: [String]
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
