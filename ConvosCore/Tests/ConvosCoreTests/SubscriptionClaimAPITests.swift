@testable import ConvosCore
import Foundation
import Testing

/// Covers the subscription-claim response mapping: the full status matrix,
/// the 202 pending path (not emitted at launch but part of the contract),
/// the rejection-reason enum including forward-compatible unknown values,
/// and the pending-contest deadline parsing.
@Suite("Subscription Claim API")
struct SubscriptionClaimAPITests {
    private func outcome(status: Int, json: String) throws -> SubscriptionClaimOutcome {
        try ConvosAPIClient.subscriptionClaimOutcome(statusCode: status, data: Data(json.utf8))
    }

    private func claimError(status: Int, json: String) -> SubscriptionClaimError? {
        do {
            _ = try outcome(status: status, json: json)
            return nil
        } catch let error as SubscriptionClaimError {
            return error
        } catch {
            return nil
        }
    }

    @Test("200 maps to transferred with the decoded subscription")
    func transferredDecodes() throws {
        let json = """
        {
            "subscription": {
                "tier": "plus",
                "period": "monthly",
                "status": "active",
                "productId": "com.convos.plus.monthly",
                "currentPeriodEnd": "2026-08-15T00:00:00Z",
                "willRenew": true,
                "isInTrial": false
            }
        }
        """
        guard case .transferred(let subscription) = try outcome(status: 200, json: json) else {
            Issue.record("Expected transferred")
            return
        }
        #expect(subscription.tier == .plus)
        #expect(subscription.status == .active)
    }

    @Test("202 maps to pending with the contest deadline")
    func pendingDecodes() throws {
        let json = #"{ "status": "pending", "contestEndsAt": "2026-07-18T10:00:00Z" }"#
        guard case .pending(let contestEndsAt) = try outcome(status: 202, json: json) else {
            Issue.record("Expected pending")
            return
        }
        #expect(contestEndsAt != nil)
    }

    @Test("Typed failures map by status and code")
    func failureMatrix() {
        let invalidProof = claimError(status: 400, json: #"{ "error": "Invalid claim proof", "code": "invalid_claim_proof" }"#)
        guard case .invalidProof = invalidProof else {
            Issue.record("Expected invalidProof, got \(String(describing: invalidProof))")
            return
        }
        let attestation = claimError(status: 403, json: #"{ "error": "App attestation required", "code": "app_check_required" }"#)
        guard case .appAttestationRequired = attestation else {
            Issue.record("Expected appAttestationRequired")
            return
        }
        let notFound = claimError(status: 404, json: #"{ "error": "No subscription found", "code": "subscription_not_found" }"#)
        guard case .notFound = notFound else {
            Issue.record("Expected notFound")
            return
        }
        let rateLimited = claimError(status: 429, json: #"{ "error": "Too many requests" }"#)
        guard case .rateLimited = rateLimited else {
            Issue.record("Expected rateLimited")
            return
        }
        let server = claimError(status: 500, json: #"{ "error": "Failed to claim subscription" }"#)
        guard case .serverError = server else {
            Issue.record("Expected serverError")
            return
        }
    }

    @Test("409 rejection reasons parse, including the pending-contest deadline")
    func rejectionReasons() {
        let cases: [(String, SubscriptionClaimRejectionReason)] = [
            ("not_entitled", .notEntitled),
            ("cooldown", .cooldown),
            ("undo_consumed", .undoConsumed),
            ("transfer_frozen", .transferFrozen),
            ("lineage_unresolved", .lineageUnresolved),
        ]
        for (raw, expected) in cases {
            let json = #"{ "error": "Subscription cannot be claimed", "code": "subscription_claim_rejected", "reason": "\#(raw)" }"#
            guard case .rejected(let reason) = claimError(status: 409, json: json) else {
                Issue.record("Expected rejected for reason \(raw)")
                continue
            }
            #expect(reason == expected)
        }

        let pendingJson = """
        {
            "error": "Subscription cannot be claimed",
            "code": "subscription_claim_rejected",
            "reason": "pending_contest",
            "contestEndsAt": "2026-07-18T10:00:00Z"
        }
        """
        guard case .rejected(.pendingContest(let contestEndsAt)) = claimError(status: 409, json: pendingJson) else {
            Issue.record("Expected pendingContest")
            return
        }
        #expect(contestEndsAt != nil)
    }

    @Test("Unknown rejection reasons fall through generically")
    func unknownReasonIsGeneric() {
        let json = #"{ "error": "Subscription cannot be claimed", "code": "subscription_claim_rejected", "reason": "owner_active" }"#
        guard case .rejected(.unknown(let raw)) = claimError(status: 409, json: json) else {
            Issue.record("Expected unknown rejection reason")
            return
        }
        #expect(raw == "owner_active")
    }
}
