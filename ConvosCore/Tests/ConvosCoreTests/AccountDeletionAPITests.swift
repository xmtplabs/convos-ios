@testable import ConvosCore
import Foundation
import Testing

/// Covers the account-deletion wire layer: response decoding, the
/// code-keyed terminal identity-deleted mapping on the SIWE mint path,
/// typed 409 conflict parsing, and the process-wide reauth suspension
/// switch.
@Suite("Account Deletion API")
struct AccountDeletionAPITests {
    // MARK: - DELETE /v2/accounts/me response

    @Test("Deletion response decodes the contract success body")
    func deletionResponseDecodes() throws {
        let json = """
        {
            "status": "deleted",
            "operationId": "0d9b2c62-6c5e-4f5a-9d55-3fb2b31a4a4e",
            "deletedAt": "2026-07-15T10:00:00Z",
            "purgeWindowHours": 24
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ConvosAPI.AccountDeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == "deleted")
        #expect(response.operationId == "0d9b2c62-6c5e-4f5a-9d55-3fb2b31a4a4e")
        #expect(response.purgeWindowHours == 24)
        #expect(response.deletedAt != nil)
    }

    @Test("Deletion response tolerates missing optional fields")
    func deletionResponseToleratesMissingOptionals() throws {
        let json = """
        { "status": "deleted", "operationId": "abc" }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ConvosAPI.AccountDeletionResponse.self, from: Data(json.utf8))
        #expect(response.deletedAt == nil)
        #expect(response.purgeWindowHours == nil)
    }

    @Test("Mock client echoes the operation id and reports success")
    func mockClientEchoesOperationId() async throws {
        let operationId = UUID()
        let response = try await MockAPIClient().deleteAccount(operationId: operationId, jwt: "jwt")
        #expect(response.status == "deleted")
        #expect(response.operationId == operationId.uuidString.lowercased())
    }

    // MARK: - Mint-path terminal mapping

    @Test("identity_deleted code maps to the terminal SIWE error, keyed on code not status")
    func identityDeletedKeyedOnCode() {
        let body = Data(#"{ "error": "This identity has been deleted", "code": "identity_deleted" }"#.utf8)
        // The contract ships it with 410, but the mapping must follow the
        // machine-readable code wherever it appears.
        for status in [410, 401, 403, 500] {
            let error = ConvosAPIClient.siweExchangeFailure(statusCode: status, data: body)
            guard case SIWEAuthError.identityDeleted = error else {
                Issue.record("Expected identityDeleted for status \(status), got \(error)")
                continue
            }
        }
    }

    @Test("Generic 401 maps to invalidNonceOrSignature and never confirms deletion")
    func generic401NeverConfirms() {
        let body = Data(#"{ "error": "Invalid SIWE" }"#.utf8)
        let error = ConvosAPIClient.siweExchangeFailure(statusCode: 401, data: body)
        guard case SIWEAuthError.invalidNonceOrSignature = error else {
            Issue.record("Expected invalidNonceOrSignature, got \(error)")
            return
        }
    }

    @Test("Remaining mint failures keep their existing typed mapping")
    func mintFailureMappingUnchanged() {
        let body = Data(#"{ "error": "nope" }"#.utf8)
        guard case APIError.badRequest = ConvosAPIClient.siweExchangeFailure(statusCode: 400, data: body) else {
            Issue.record("Expected badRequest for 400")
            return
        }
        guard case SIWEAuthError.deviceDisabled = ConvosAPIClient.siweExchangeFailure(statusCode: 403, data: body) else {
            Issue.record("Expected deviceDisabled for 403")
            return
        }
        guard case SIWEAuthError.rateLimited = ConvosAPIClient.siweExchangeFailure(statusCode: 429, data: body) else {
            Issue.record("Expected rateLimited for 429")
            return
        }
        guard case APIError.serverError = ConvosAPIClient.siweExchangeFailure(statusCode: 500, data: body) else {
            Issue.record("Expected serverError for 500")
            return
        }
    }

    // MARK: - Typed 409 parsing

    @Test("Conflict details parse the verify mismatch envelope with the additive claimable flag")
    func conflictDetailsParseClaimable() {
        let body = Data("""
        {
            "error": "Subscription belongs to a different account. Contact support.",
            "code": "subscription_account_mismatch",
            "claimable": true
        }
        """.utf8)
        let details = APIConflictDetails.parse(from: body)
        #expect(details.code == BackendErrorCode.subscriptionAccountMismatch)
        #expect(details.claimable == true)
        #expect(details.reason == nil)
        #expect(details.message?.isEmpty == false)
    }

    @Test("Conflict details keep unknown reasons as opaque strings")
    func conflictDetailsUnknownReason() {
        let body = Data("""
        {
            "error": "Subscription cannot be claimed",
            "code": "subscription_claim_rejected",
            "reason": "some_future_reason"
        }
        """.utf8)
        let details = APIConflictDetails.parse(from: body)
        #expect(details.code == BackendErrorCode.subscriptionClaimRejected)
        #expect(details.reason == "some_future_reason")
        #expect(details.claimable == nil)
    }

    @Test("Conflict details tolerate a non-envelope body")
    func conflictDetailsTolerateGarbage() {
        let details = APIConflictDetails.parse(from: Data("not json".utf8))
        #expect(details.code == nil)
        #expect(details.message == nil)
        #expect(details.claimable == nil)
        #expect(details.reason == nil)
    }

    // MARK: - Reauth suspension

    @Test("Reauth suspension flips process-wide and resets")
    func reauthSuspensionFlips() {
        let suspension = ReauthSuspension.shared
        #expect(!suspension.isSuspended)
        suspension.set(true)
        #expect(suspension.isSuspended)
        suspension.set(false)
        #expect(!suspension.isSuspended)
    }
}
