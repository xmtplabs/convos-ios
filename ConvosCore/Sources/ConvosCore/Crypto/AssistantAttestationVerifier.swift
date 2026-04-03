import CryptoKit
import Foundation

public enum AssistantAttestationVerifier {
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
        guard let resolved = keyset.cachedResolveKey(for: kid) else {
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
            Log.info("[Attestation] timestamp too old for \(inboxId.prefix(8)): age=\(Int(age))s, max=\(Int(maxAge))s")
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
