@testable import ConvosCore
import Foundation
import GRDB
import os
import Testing

@Suite("CreditBalanceWriter Tests", .serialized)
struct CreditBalanceWriterTests {
    @Test("concurrent refresh calls share a single in-flight HTTP request")
    func testConcurrentRefreshDeduplicates() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient(
            sleepNanoseconds: 50_000_000  // 50ms — long enough for both callers to overlap
        )
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        async let first: Void = writer.refresh(force: true)
        async let second: Void = writer.refresh(force: true)
        _ = await (first, second)

        let count = await apiClient.callCount
        #expect(count == 1, "Concurrent refresh calls must share the same in-flight HTTP request")

        let row: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(row != nil, "Both callers must see the upserted row when they return")
    }

    @Test("non-forced refresh within the TTL window is a no-op")
    func testNonForcedRefreshWithinTTLIsNoOp() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient()
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        await writer.refresh(force: false)
        let countAfterFirst = await apiClient.callCount
        #expect(countAfterFirst == 1)

        await writer.refresh(force: false)
        let countAfterSecond = await apiClient.callCount
        #expect(
            countAfterSecond == 1,
            "Second non-forced refresh inside the TTL window must skip the HTTP call"
        )
    }

    @Test("forced refresh bypasses the TTL window")
    func testForcedRefreshBypassesTTL() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient()
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        await writer.refresh(force: false)
        await writer.refresh(force: true)

        let count = await apiClient.callCount
        #expect(count == 2, "Forced refresh must always hit the network, ignoring the TTL")
    }

    @Test("beginAccountWipe drops an in-flight refresh's write")
    func testBeginAccountWipeDropsInFlightWrite() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient(
            sleepNanoseconds: 300_000_000  // long enough for the wipe to land mid-fetch
        )
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        let refreshTask: Task<Void, Never> = Task { await writer.refresh(force: true) }
        try await Task.sleep(nanoseconds: 100_000_000)  // let the refresh enter its network call
        await writer.beginAccountWipe()
        await refreshTask.value

        let count = await apiClient.callCount
        #expect(count == 1)
        let row: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(row == nil, "A refresh spanning the account wipe must not write the stale balance")

        writer.endAccountWipe()
        await writer.refresh(force: false)
        let countAfterWipe = await apiClient.callCount
        #expect(
            countAfterWipe == 2,
            "The wipe must reset the TTL so the next account's first refresh is not debounced"
        )
        let rowAfterWipe: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(rowAfterWipe != nil, "Post-wipe refreshes must write normally again")
    }

    @Test("refresh while the wipe latch is set is a rejected no-op; refresh after endAccountWipe succeeds")
    func testWipeLatchRejectsRefreshUntilEnded() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient()
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        await writer.beginAccountWipe()

        await writer.refresh(force: true)
        let countWhileLatched = await apiClient.callCount
        #expect(
            countWhileLatched == 0,
            "A refresh entering the quiesce-to-delete gap must be rejected outright, not fetch and write"
        )
        let rowWhileLatched: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(rowWhileLatched == nil, "No row may land while the wipe latch is set")

        writer.endAccountWipe()

        await writer.refresh(force: true)
        let countAfterEnd = await apiClient.callCount
        #expect(countAfterEnd == 1, "Ending the latch must reopen the writer for the next account")
        let rowAfterEnd: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(rowAfterEnd != nil, "The next account's refresh must write normally after the latch ends")
    }

    @Test("API failure does not advance the TTL window")
    func testFailureDoesNotAdvanceTTL() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient: StubCreditBalanceAPIClient = StubCreditBalanceAPIClient(shouldFail: true)
        let writer: CreditBalanceWriter = CreditBalanceWriter(
            databaseWriter: dbManager.dbWriter,
            apiClient: apiClient
        )

        await writer.refresh(force: false)
        await writer.refresh(force: false)

        let count = await apiClient.callCount
        #expect(
            count == 2,
            "A failed refresh must not update lastFetchedAt — the next attempt should retry instead of being TTL-gated"
        )

        let row: DBCreditBalance? = try await dbManager.dbReader.read { db in
            try DBCreditBalance.fetchOne(db)
        }
        #expect(row == nil, "Failed refresh must not write a row")
    }
}

/// Wraps `MockAPIClient` to inherit no-op defaults for every protocol method
/// except `getCreditBalance`, which is the only one the writer exercises. The
/// override counts calls, optionally delays the response (to overlap
/// concurrent callers), and can be flipped into a failure mode.
private final class StubCreditBalanceAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    private let delegate: MockAPIClient = MockAPIClient()
    private let sleepNanoseconds: UInt64
    private let shouldFail: Bool
    private let counter: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int {
        counter.withLock { $0 }
    }

    init(sleepNanoseconds: UInt64 = 0, shouldFail: Bool = false) {
        self.sleepNanoseconds = sleepNanoseconds
        self.shouldFail = shouldFail
    }

    func getCreditBalance() async throws -> CreditBalance {
        counter.withLock { $0 += 1 }
        if sleepNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        if shouldFail {
            throw StubError.simulatedFailure
        }
        return CreditBalance(
            balance: 1_000,
            monthlyGrant: 2_000,
            monthlyGrantUsed: 1_000,
            nextRefreshAt: Date(timeIntervalSince1970: 1_700_000_000),
            periodLabel: "test"
        )
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        try delegate.request(for: path, method: method, queryParameters: queryParameters)
    }
    func registerDevice(deviceId: String, pushToken: String?) async throws {
        try await delegate.registerDevice(deviceId: deviceId, pushToken: pushToken)
    }
    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        try await delegate.authenticate(appCheckToken: appCheckToken, retryCount: retryCount)
    }
    func authenticateWithSIWE(appCheckToken: String, signing: BackendAuthSigningContext) async throws -> String {
        try await delegate.authenticateWithSIWE(appCheckToken: appCheckToken, signing: signing)
    }
    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {
        delegate.updateSIWESigningContext(context)
    }
    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse {
        try await delegate.accountAuthCheck(jwt: jwt)
    }
    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String {
        try await delegate.uploadAttachment(data: data, filename: filename, contentType: contentType, acl: acl)
    }
    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        try await delegate.uploadAttachmentAndExecute(data: data, filename: filename, afterUpload: afterUpload)
    }
    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        try await delegate.getPresignedUploadURL(filename: filename, contentType: contentType)
    }
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        try await delegate.subscribeToTopics(deviceId: deviceId, clientId: clientId, topics: topics)
    }
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        try await delegate.unsubscribeFromTopics(clientId: clientId, topics: topics)
    }
    func unregisterInstallation(clientId: String) async throws {
        try await delegate.unregisterInstallation(clientId: clientId)
    }
    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        try await delegate.renewAssetsBatch(assetKeys: assetKeys)
    }
    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await delegate.requestAgentJoin(joinRequest, forceErrorCode: forceErrorCode)
    }
    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        try await delegate.initiateCloudConnection(serviceId: serviceId, redirectUri: redirectUri)
    }
    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        try await delegate.completeCloudConnection(connectionRequestId: connectionRequestId)
    }
    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] {
        try await delegate.listCloudConnections()
    }
    func revokeCloudConnection(connectionId: String) async throws {
        try await delegate.revokeCloudConnection(connectionId: connectionId)
    }
    func getSubscription() async throws -> UserSubscription? {
        try await delegate.getSubscription()
    }
    func verifySubscription(jwsRepresentation: String) async throws -> UserSubscription {
        try await delegate.verifySubscription(jwsRepresentation: jwsRepresentation)
    }

    enum StubError: Error {
        case simulatedFailure
    }
}
