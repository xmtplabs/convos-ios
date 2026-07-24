import Foundation

/// Machine-readable backend error codes the client branches on. Error
/// envelope invariant: every 4xx/5xx body is `{ "error": string }` plus an
/// optional snake_case `"code"` and optional `"reason"`/`"details"`. The
/// `error` string is display/log text and is never matched.
public enum BackendErrorCode {
    /// Terminal deletion-barrier response at token mint. The only signal
    /// (besides a 200 from the deletion endpoint) a client may treat as
    /// account-deletion confirmation.
    public static let identityDeleted: String = "identity_deleted"
    /// Subscription verify: provider key belongs to a different (possibly
    /// deleted) account. Carries an additive optional `claimable` flag.
    public static let subscriptionAccountMismatch: String = "subscription_account_mismatch"
    /// Subscription claim: proof invalid (bad JWS, stale signedDate, not the
    /// latest transaction, dead or unknown Google token).
    public static let invalidClaimProof: String = "invalid_claim_proof"
    /// Subscription claim: provider key has no row and no tombstone.
    public static let subscriptionNotFound: String = "subscription_not_found"
    /// Subscription claim: rejected (owner demonstrably live, or transfer
    /// cooldown); see the envelope's `reason`.
    public static let subscriptionClaimRejected: String = "subscription_claim_rejected"
}

/// Decoded form of the backend error envelope.
struct BackendErrorEnvelope: Decodable {
    let error: String?
    let code: String?
    let claimable: Bool?
    let reason: String?
    /// Carried by claim rejections whose reason is `pending_contest` (and
    /// by the 202 pending body, decoded separately).
    let contestEndsAt: String?

    var contestEndsAtDate: Date? {
        guard let contestEndsAt else { return nil }
        return ISO8601DateFormatter().date(from: contestEndsAt)
    }

    static func parse(from data: Data) -> BackendErrorEnvelope? {
        try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data)
    }
}

/// Typed payload for HTTP 409 responses. Mirrors the envelope's
/// machine-readable fields so call sites can branch without re-parsing
/// response bodies (e.g. `subscription_account_mismatch` + `claimable` on
/// subscription verify).
public struct APIConflictDetails: Sendable, Equatable {
    public let code: String?
    public let message: String?
    public let claimable: Bool?
    public let reason: String?

    public init(code: String?, message: String?, claimable: Bool?, reason: String?) {
        self.code = code
        self.message = message
        self.claimable = claimable
        self.reason = reason
    }

    static func parse(from data: Data) -> APIConflictDetails {
        let envelope = BackendErrorEnvelope.parse(from: data)
        return APIConflictDetails(
            code: envelope?.code,
            message: envelope?.error,
            claimable: envelope?.claimable,
            reason: envelope?.reason
        )
    }
}
