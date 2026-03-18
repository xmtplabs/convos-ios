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
    ) async -> Bool {
        guard let publicKey = await keyset.publicKey(for: kid) else {
            return false
        }
        return verifySignature(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTimestamp,
            publicKey: publicKey,
            referenceDate: referenceDate,
            maxAge: maxAge
        )
    }

    public static func verifyCached(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        kid: String,
        keyset: any AgentKeysetProviding,
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 86400
    ) -> Bool {
        guard let publicKey = keyset.cachedPublicKey(for: kid) else {
            return false
        }
        return verifySignature(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTimestamp,
            publicKey: publicKey,
            referenceDate: referenceDate,
            maxAge: maxAge
        )
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

        guard let timestampDate = ISO8601DateFormatter().date(from: attestationTimestamp) else {
            return false
        }

        if abs(referenceDate.timeIntervalSince(timestampDate)) > maxAge {
            return false
        }

        let message = Data((inboxId + attestationTimestamp).utf8)
        return publicKey.isValidSignature(signatureData, for: message)
    }
}
