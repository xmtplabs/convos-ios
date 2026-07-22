@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Covers the dev-only agent-variant three-call plumbing: the same `variantId`
/// captured at build start must ride the generation call (top-level body
/// field), the join call (`options.variantId`), and the join-status poll
/// (`?variantId=` query param), each in its own shape, with no split-brain.
///
/// The generation and join legs are threaded from the persisted row and are
/// asserted end-to-end via a recording client. The join-status poll leg lives
/// in `SessionManager.addAgentToConversation` (outside the extracted, unit-
/// testable `awaitProvisionedAgentInbox` helper, for the same reason
/// `DirectAddProvisionPollTests` exists), so it is exercised in the E2E pass;
/// here we lock the query-param shape it relies on.
@Suite("Agent variant three-call plumbing")
struct AgentVariantPlumbingTests {
    // MARK: - Wire shapes (`.strict()` placement)

    @Test("Generation request encodes variantId as a top-level field, never under inputs")
    func generationRequestTopLevelVariantId() throws {
        let request = ConvosAPI.AgentTemplateGenerationRequest(
            source: "ios-app",
            inputs: .init(text: "build me a chef"),
            clientDeviceId: "dev-1",
            publishStatus: "unlisted",
            variantId: "pr-1234"
        )
        let object = try Self.jsonObject(request)
        #expect(object["variantId"] as? String == "pr-1234")
        let inputs = object["inputs"] as? [String: Any]
        #expect(inputs?["variantId"] == nil)
    }

    @Test("Generation request omits variantId when nil so default builds stay byte-identical")
    func generationRequestOmitsNilVariantId() throws {
        let request = ConvosAPI.AgentTemplateGenerationRequest(
            source: "ios-app",
            inputs: .init(text: "build me a chef"),
            clientDeviceId: "dev-1",
            publishStatus: "unlisted"
        )
        let object = try Self.jsonObject(request)
        #expect(object.keys.contains("variantId") == false)
    }

    @Test("Join request nests variantId under options, not at the top level")
    func joinRequestNestsVariantIdUnderOptions() throws {
        let request = ConvosAPI.AgentJoinRequest(
            conversationId: "convo-1",
            templateId: "tmpl-1",
            options: ConvosAPI.AgentJoinOptions(onboarding: nil, variantId: "pr-1234")
        )
        let object = try Self.jsonObject(request)
        #expect(object["variantId"] == nil)
        let options = object["options"] as? [String: Any]
        #expect(options?["variantId"] as? String == "pr-1234")
    }

    @Test("Join request carries idempotencyKey top-level as a lowercase string, omitted when nil")
    func joinRequestIdempotencyKeyEncoding() throws {
        // Uppercase input proves the type normalizes before encoding: the
        // wire value must be lowercase regardless of the raw value's casing.
        let key = try #require(ConvosAPI.JoinIdempotencyKey(rawValue: "6F0F7A8E-1B2C-4D3E-8F4A-5B6C7D8E9F0A"))
        let keyed = ConvosAPI.AgentJoinRequest(
            conversationId: "convo-1",
            templateId: "tmpl-1",
            idempotencyKey: key
        )
        let object = try Self.jsonObject(keyed)
        #expect(object["idempotencyKey"] as? String == "6f0f7a8e-1b2c-4d3e-8f4a-5b6c7d8e9f0a")

        // Nil-omitted so default joins stay byte-identical to shipped builds.
        let unkeyed = ConvosAPI.AgentJoinRequest(conversationId: "convo-1", templateId: "tmpl-1")
        #expect(try Self.jsonObject(unkeyed).keys.contains("idempotencyKey") == false)
    }

    @Test("Join options omit variantId when nil")
    func joinOptionsOmitNilVariantId() throws {
        let object = try Self.jsonObject(ConvosAPI.AgentJoinOptions(onboarding: "agent-builder"))
        #expect(object.keys.contains("variantId") == false)
        #expect(object["onboarding"] as? String == "agent-builder")
    }

    // MARK: - Join-status poll query param

    @Test("Join-status poll query carries the persisted variantId, omitted when nil")
    func joinStatusPollThreadsPersistedVariantId() throws {
        // The slug persisted on the row (carried through the join options) is what
        // getAgentJoinStatus turns into the load-bearing `?variantId=` query param.
        #expect(ConvosAPIClient.agentJoinStatusQueryParameters(variantId: "pr-1234") == ["variantId": "pr-1234"])
        // No selection -> no query param, so a default poll stays byte-identical.
        #expect(ConvosAPIClient.agentJoinStatusQueryParameters(variantId: nil) == nil)

        // And the constructed parameters actually land in the request URL.
        let api = ConvosAPIClientFactory.client(
            environment: .local(config: ConvosConfiguration(
                apiBaseURL: "https://api.example.com",
                appGroupIdentifier: "group.test",
                relyingPartyIdentifier: "example.com",
                siweConfiguration: SIWEConfiguration(domain: "example.com", uri: "https://example.com", chainId: 1)
            ))
        )
        let request = try api.request(
            for: "v2/agents/join/inst-1",
            method: "GET",
            queryParameters: ConvosAPIClient.agentJoinStatusQueryParameters(variantId: "pr-1234")
        )
        #expect(request.url?.query?.contains("variantId=pr-1234") == true)
    }

    // MARK: - Profile variant stamp (banner/badge source)

    @Test("Profile.variant decodes the worker-stamped JSON marker")
    func profileVariantDecodesStamp() {
        let json = #"{"slug":"pr-1234","label":"Q+A","whatToTest":"asks clarifying Qs","prUrl":"https://github.com/x/pull/1234"}"#
        let profile = Profile(
            inboxId: "agent-inbox",
            conversationId: "convo-1",
            name: "Q+A Agent",
            avatar: nil,
            isAgent: true,
            metadata: ["variant": .string(json)]
        )
        let stamp = profile.variant
        #expect(stamp?.slug == "pr-1234")
        #expect(stamp?.label == "Q+A")
        #expect(stamp?.whatToTest == "asks clarifying Qs")
        #expect(stamp?.prUrl == "https://github.com/x/pull/1234")
    }

    @Test("Profile.variant is nil for an absent, malformed, or partial marker")
    func profileVariantDefensiveDecode() {
        let absent = Profile(inboxId: "a", conversationId: "c", name: nil, avatar: nil, metadata: [:])
        #expect(absent.variant == nil)
        let malformed = Profile(inboxId: "a", conversationId: "c", name: nil, avatar: nil, metadata: ["variant": .string("{not json")])
        #expect(malformed.variant == nil)
        let partial = Profile(inboxId: "a", conversationId: "c", name: nil, avatar: nil, metadata: ["variant": .string(#"{"slug":"pr-1"}"#)])
        #expect(partial.variant == nil)
    }

    // MARK: - Capture-once threading (generation + join read the same row value)

    @Test("variantId persisted on the row reaches both the generation and join calls unchanged")
    func variantIdThreadsFromRowToGenerationAndJoin() async throws {
        let database = try Self.makeDatabase()
        let api = VariantRecordingStubAPIClient()
        let repository = Self.makeRepository(database: database, apiClient: api)
        await repository.startGeneration(
            prompt: "build me a chef",
            conversationId: "convo-1",
            slug: "chef.abcd",
            attachments: [],
            connections: [],
            variantId: "pr-1234"
        )
        let row = try await Self.waitForInvited(conversationId: "convo-1", in: database)
        #expect(row?.statusValue == .invited)
        #expect(api.generationVariantId == "pr-1234")
        #expect(api.joinVariantId == "pr-1234")
    }

    // MARK: - Helpers

    private static func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object)
    }

    private static func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private static func makeRepository(
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

    private static func waitForInvited(
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
            if let row, row.statusValue == .invited { return row }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await database.read { db in
            try DBAgentTemplateGeneration
                .filter(DBAgentTemplateGeneration.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }
}

/// Records the `variantId` handed to the generation and join calls so the test
/// can assert the same captured value rides both. With no join handler
/// configured, the repository's invite step falls back to the raw API client,
/// which derives the join `options` from the persisted row.
private final class VariantRecordingStubAPIClient: TestStubAPIClient {
    private let lock: NSLock = NSLock()
    private var capturedGenerationVariantId: String?
    private var capturedJoinVariantId: String?

    var generationVariantId: String? { lock.withLock { capturedGenerationVariantId } }
    var joinVariantId: String? { lock.withLock { capturedJoinVariantId } }

    override func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        lock.withLock { capturedGenerationVariantId = variantId }
        return ConvosAPI.AgentTemplateGenerationResponse(
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
            templateId: "tmpl-1",
            error: nil
        )
    }

    override func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        lock.withLock { capturedJoinVariantId = joinRequest.options?.variantId }
        return ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }
}
