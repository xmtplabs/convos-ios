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
            return false
        }

        guard let timestampDate = parseISO8601(attestationTimestamp) else {
            return false
        }

        if abs(referenceDate.timeIntervalSince(timestampDate)) > maxAge {
            return false
        }

        let rawMessage = Data((inboxId + attestationTimestamp).utf8)
        let digest = SHA256.hash(data: rawMessage)
        let digestData = Data(digest)
        return publicKey.isValidSignature(signatureData, for: digestData)
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
