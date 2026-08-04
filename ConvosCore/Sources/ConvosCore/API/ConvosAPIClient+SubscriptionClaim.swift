import Foundation

// MARK: - Wire models

extension ConvosAPI {
    struct SubscriptionClaimRequest: Encodable {
        let platform: String
        let jwsRepresentation: String
    }

    struct SubscriptionClaimPendingResponse: Decodable {
        let status: String
        let contestEndsAt: Date?
    }
}

/// Outcome of `POST /v2/accounts/me/subscription/claim`.
public enum SubscriptionClaimOutcome: Sendable {
    /// Transfer committed (tombstone restoration, immediate live transfer,
    /// or idempotent replay when the caller already owns it).
    case transferred(UserSubscription)
    /// Live-tier claim subject to the contest window: the transfer
    /// executes at `contestEndsAt` unless the previous owner objects. No
    /// push comes to the claimant — re-verify after the window.
    case pending(contestEndsAt: Date?)
}

/// Machine-readable claim rejection reasons. Unknown values must be
/// handled generically (`unknown`), never crashed on or string-matched.
public enum SubscriptionClaimRejectionReason: Sendable, Equatable {
    /// Provider says the subscription is expired, revoked, or paused.
    case notEntitled
    /// The lineage transferred within the last 30 days.
    case cooldown
    /// The one-shot undo for this transfer was already spent or expired;
    /// recovery is support-mediated from here.
    case undoConsumed
    /// Post-undo lineage freeze; support-only until an operator clears it.
    case transferFrozen
    /// Provider token-chain quarantine; retryable later.
    case lineageUnresolved
    /// A contest-window transfer is already pending for this lineage.
    case pendingContest(contestEndsAt: Date?)
    case unknown(String?)

    static func parse(_ raw: String?, contestEndsAt: Date?) -> SubscriptionClaimRejectionReason {
        switch raw {
        case "not_entitled": return .notEntitled
        case "cooldown": return .cooldown
        case "undo_consumed": return .undoConsumed
        case "transfer_frozen": return .transferFrozen
        case "lineage_unresolved": return .lineageUnresolved
        case "pending_contest": return .pendingContest(contestEndsAt: contestEndsAt)
        default: return .unknown(raw)
        }
    }
}

public enum SubscriptionClaimError: Error {
    /// No claimable ownership mismatch is on record; verify first.
    case noCandidate
    /// Proof rejected: malformed/unverifiable JWS, dead or unknown token,
    /// or not the subscription's latest transaction.
    case invalidProof(String?)
    /// App attestation missing, invalid, or the limited-use token was
    /// already consumed. Retry with a fresh limited-use token.
    case appAttestationRequired
    /// Provider key has no subscription row and no tombstone.
    case notFound
    case rejected(SubscriptionClaimRejectionReason)
    case rateLimited
    case serverError(String?)
}

// MARK: - Client

extension ConvosAPIClient {
    func claimSubscription(jwsRepresentation: String, appCheckToken: String) async throws -> SubscriptionClaimOutcome {
        var request = try authenticatedRequest(for: "v2/accounts/me/subscription/claim", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Limited-use attestation: the server consumes it, so the caller
        // must mint a fresh one per attempt (never the cached session
        // token).
        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        let body = ConvosAPI.SubscriptionClaimRequest(platform: "apple", jwsRepresentation: jwsRepresentation)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        return try Self.subscriptionClaimOutcome(statusCode: httpResponse.statusCode, data: data)
    }

    /// Maps a claim response to its typed outcome or error. Static and
    /// pure so the full status matrix is unit-testable without a network.
    static func subscriptionClaimOutcome(statusCode: Int, data: Data) throws -> SubscriptionClaimOutcome {
        switch statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(ConvosAPI.VerifySubscriptionResponse.self, from: data)
            return .transferred(response.subscription)
        case 202:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(ConvosAPI.SubscriptionClaimPendingResponse.self, from: data)
            return .pending(contestEndsAt: response.contestEndsAt)
        case 400:
            throw SubscriptionClaimError.invalidProof(parseErrorMessage(from: data))
        case 403:
            throw SubscriptionClaimError.appAttestationRequired
        case 404:
            throw SubscriptionClaimError.notFound
        case 409:
            let envelope = BackendErrorEnvelope.parse(from: data)
            let reason = SubscriptionClaimRejectionReason.parse(
                envelope?.reason,
                contestEndsAt: envelope?.contestEndsAtDate
            )
            throw SubscriptionClaimError.rejected(reason)
        case 429:
            throw SubscriptionClaimError.rateLimited
        default:
            throw SubscriptionClaimError.serverError(parseErrorMessage(from: data))
        }
    }
}
