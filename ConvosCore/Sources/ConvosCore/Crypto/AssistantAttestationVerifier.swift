import CryptoKit
import Foundation
import os

public enum AssistantAttestationVerifier {
    /// Memoizes negative verdicts keyed by inputs that uniquely determine
    /// the result. Staleness fails monotonically (age only grows for a
    /// fixed `attestationTimestamp`) and signature verification is
    /// deterministic, so once a `(inboxId, kid, attestationTimestamp)`
    /// triple is known-unverified it stays unverified. When the agent
    /// rotates to a new attestation the timestamp changes and the cache
    /// key changes with it, so no false negatives. Positive verdicts are
    /// not cached because they can transition to stale as time advances.
    private struct NegativeCacheKey: Hashable {
        let inboxId: String
        let kid: String
        let attestationTimestamp: String
    }

    private static let negativeCache: OSAllocatedUnfairLock<Set<NegativeCacheKey>>
        = OSAllocatedUnfairLock(initialState: [])

    public static func verify(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        kid: String,
        keyset: any AgentKeysetProviding,
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 86400
    ) async -> AgentVerification {
        guard let resolved = await keyset.resolveKey(for: kid) else {
            return .unverified
        }
        let valid = verifySignature(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTimestamp,
            publicKey: resolved.publicKey,
            referenceDate: referenceDate,
            maxAge: maxAge
        )
        return valid ? .verified(resolved.issuer) : .unverified
    }

    public static func verifyCached(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        kid: String,
        keyset: any AgentKeysetProviding,
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 86400
    ) -> AgentVerification {
        let cacheKey = NegativeCacheKey(
            inboxId: inboxId,
            kid: kid,
            attestationTimestamp: attestationTimestamp
        )
        if negativeCache.withLock({ $0.contains(cacheKey) }) {
            return .unverified
        }
        guard let resolved = keyset.cachedResolveKey(for: kid) else {
            negativeCache.withLock { _ = $0.insert(cacheKey) }
            return .unverified
        }
        let valid = verifySignature(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTimestamp,
            publicKey: resolved.publicKey,
            referenceDate: referenceDate,
            maxAge: maxAge
        )
        if !valid {
            negativeCache.withLock { _ = $0.insert(cacheKey) }
            return .unverified
        }
        return .verified(resolved.issuer)
    }

    private static func verifySignature(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        publicKey: Curve25519.Signing.PublicKey,
        referenceDate: Date,
        maxAge: TimeInterval
    ) -> Bool {
        guard let signatureData = try? attestation.base64URLDecoded() else {
            Log.info("[Attestation] failed to decode signature base64url for \(inboxId.prefix(8))")
            return false
        }

        guard let timestampDate = parseISO8601(attestationTimestamp) else {
            Log.info("[Attestation] failed to parse timestamp '\(attestationTimestamp)' for \(inboxId.prefix(8))")
            return false
        }

        let age = abs(referenceDate.timeIntervalSince(timestampDate))
        if age > maxAge {
            Log.debug("[Attestation] timestamp too old for \(inboxId.prefix(8)): age=\(Int(age))s, max=\(Int(maxAge))s")
            return false
        }

        let rawMessage = Data((inboxId + attestationTimestamp).utf8)
        let digest = SHA256.hash(data: rawMessage)
        let digestData = Data(digest)
        let valid = publicKey.isValidSignature(signatureData, for: digestData)
        if !valid {
            Log.info("[Attestation] signature invalid for \(inboxId.prefix(8)), msg_len=\(rawMessage.count), sig_len=\(signatureData.count)")
        }
        return valid
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
