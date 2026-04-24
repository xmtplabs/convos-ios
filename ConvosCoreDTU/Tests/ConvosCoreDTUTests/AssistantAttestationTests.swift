import ConvosAppData
@testable import ConvosCore
import CryptoKit
import Foundation
import Testing

/// Phase 2 batch 3: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/AssistantAttestationTests.swift`.
///
/// Pure-unit coverage of `AssistantAttestationVerifier` using an
/// in-memory `MockAgentKeyset`. No backend, no DB — verbatim re-host.

struct MockAgentKeyset: AgentKeysetProviding {
    let keys: [String: ResolvedKey]

    init(keys: [String: ResolvedKey]) {
        self.keys = keys
    }

    init(keys: [String: Curve25519.Signing.PublicKey], issuer: AgentVerification.Issuer = .convos) {
        self.keys = keys.mapValues { ResolvedKey(publicKey: $0, issuer: issuer) }
    }

    func resolveKey(for kid: String) async -> ResolvedKey? {
        keys[kid]
    }

    func cachedResolveKey(for kid: String) -> ResolvedKey? {
        keys[kid]
    }
}

@Suite("AssistantAttestationVerifier")
struct AssistantAttestationVerifierTests {
    let privateKey = Curve25519.Signing.PrivateKey()
    let kid = "test-key-2026"

    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }
    var keyset: MockAgentKeyset { MockAgentKeyset(keys: [kid: publicKey]) }

    func sign(inboxId: String, timestamp: String) throws -> String {
        let rawMessage = Data((inboxId + timestamp).utf8)
        let digest = SHA256.hash(data: rawMessage)
        let signature = try privateKey.signature(for: Data(digest))
        return Data(signature).base64URLEncoded()
    }

    @Test("Valid attestation verifies successfully")
    func validAttestation() async throws {
        let inboxId = "abc123def456"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .verified(.convos))
    }

    @Test("Wrong inboxId fails verification")
    func wrongInboxId() async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: "correct-inbox", timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: "wrong-inbox",
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Wrong timestamp fails verification")
    func wrongTimestamp() async throws {
        let inboxId = "test-inbox"
        let realTimestamp = ISO8601DateFormatter().string(from: Date())
        let fakeTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-100))
        let signature = try sign(inboxId: inboxId, timestamp: realTimestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: fakeTimestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Tampered signature fails verification")
    func tamperedSignature() async throws {
        let inboxId = "test-inbox"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        var sigBytes = try signature.base64URLDecoded()
        sigBytes[0] ^= 0xFF
        sigBytes[1] ^= 0xFF
        let tampered = sigBytes.base64URLEncoded()

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: tampered,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Wrong key fails verification")
    func wrongKey() async throws {
        let otherKey = Curve25519.Signing.PrivateKey()
        let wrongKeyset = MockAgentKeyset(keys: [kid: otherKey.publicKey])

        let inboxId = "test-inbox"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: wrongKeyset
        )

        #expect(result == .unverified)
    }

    @Test("Unknown kid fails verification")
    func unknownKid() async throws {
        let inboxId = "test-inbox"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: "unknown-key",
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Expired timestamp fails verification")
    func expiredTimestamp() async throws {
        let inboxId = "test-inbox"
        let oldDate = Date().addingTimeInterval(-90000)
        let timestamp = ISO8601DateFormatter().string(from: oldDate)
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Future timestamp within window succeeds")
    func futureTimestampWithinWindow() async throws {
        let inboxId = "test-inbox"
        let futureDate = Date().addingTimeInterval(3600)
        let timestamp = ISO8601DateFormatter().string(from: futureDate)
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .verified(.convos))
    }

    @Test("Invalid base64 signature fails gracefully")
    func invalidBase64() async {
        let result = await AssistantAttestationVerifier.verify(
            inboxId: "test",
            attestation: "!!!not-base64!!!",
            attestationTimestamp: ISO8601DateFormatter().string(from: Date()),
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Invalid timestamp format fails gracefully")
    func invalidTimestamp() async throws {
        let inboxId = "test-inbox"
        let signature = try sign(inboxId: inboxId, timestamp: "not-a-date")

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: "not-a-date",
            kid: kid,
            keyset: keyset
        )

        #expect(result == .unverified)
    }

    @Test("Cached verification works synchronously")
    func cachedVerification() throws {
        let inboxId = "test-inbox"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signature = try sign(inboxId: inboxId, timestamp: timestamp)

        let result = AssistantAttestationVerifier.verifyCached(
            inboxId: inboxId,
            attestation: signature,
            attestationTimestamp: timestamp,
            kid: kid,
            keyset: keyset
        )

        #expect(result == .verified(.convos))
    }
}

@Suite("AgentKeysetEntry")
struct AgentKeysetEntryTests {
    @Test("Parses valid Ed25519 public key from base64url")
    func parsesValidKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let base64url = privateKey.publicKey.rawRepresentation.base64URLEncoded()

        let entry = AgentKeysetEntry(
            kid: "test",
            kty: "OKP",
            crv: "Ed25519",
            x: base64url,
            use: "sig",
            exp: nil,
            issuer: nil
        )

        #expect(entry.publicKey != nil)
        #expect(entry.publicKey?.rawRepresentation == privateKey.publicKey.rawRepresentation)
    }

    @Test("Rejects wrong key type")
    func rejectsWrongKeyType() {
        let entry = AgentKeysetEntry(
            kid: "test",
            kty: "RSA",
            crv: "Ed25519",
            x: "AAAA",
            use: "sig",
            exp: nil,
            issuer: nil
        )

        #expect(entry.publicKey == nil)
    }

    @Test("Rejects wrong curve")
    func rejectsWrongCurve() {
        let entry = AgentKeysetEntry(
            kid: "test",
            kty: "OKP",
            crv: "X25519",
            x: "AAAA",
            use: "sig",
            exp: nil,
            issuer: nil
        )

        #expect(entry.publicKey == nil)
    }

    @Test("Parses expiration date")
    func parsesExpiration() {
        let entry = AgentKeysetEntry(
            kid: "test",
            kty: "OKP",
            crv: "Ed25519",
            x: "AAAA",
            use: "sig",
            exp: "2027-03-01T00:00:00Z",
            issuer: nil
        )

        #expect(entry.expirationDate != nil)
    }

    @Test("No expiration date when nil")
    func noExpiration() {
        let entry = AgentKeysetEntry(
            kid: "test",
            kty: "OKP",
            crv: "Ed25519",
            x: "AAAA",
            use: "sig",
            exp: nil,
            issuer: nil
        )

        #expect(entry.expirationDate == nil)
    }
}

@Suite("CLI Cross-Implementation Verification")
struct CLICrossImplementationTests {
    @Test("Verifies attestation generated by convos CLI")
    func verifyCLIAttestation() async throws {
        let inboxId = "test-inbox-abc123"
        let attestation = "tVonj7Tfvb0b5D77Pg421DBgWix9dbD-Yj9Y264SuQBzvzSkLYTsThXEZuU2hEiXnpIcnbENmKnhXxIy3jUqDQ"
        let attestationTs = "2026-03-18T20:06:46.776Z"
        let attestationKid = "convos-agents-test"
        let publicKeyBase64url = "xJhoGKv6rsPn58S7VxFPVN8Z6XDerW_nr6UDZ_qjuB4"

        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyBase64url.base64URLDecoded()
        )
        let keyset = MockAgentKeyset(keys: [attestationKid: publicKey])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let referenceDate = try #require(formatter.date(from: attestationTs))

        let result = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTs,
            kid: attestationKid,
            keyset: keyset,
            referenceDate: referenceDate
        )

        #expect(result == .verified(.convos))
    }

    @Test("CLI attestation fails with wrong inboxId")
    func cliAttestationWrongInbox() async throws {
        let attestation = "tVonj7Tfvb0b5D77Pg421DBgWix9dbD-Yj9Y264SuQBzvzSkLYTsThXEZuU2hEiXnpIcnbENmKnhXxIy3jUqDQ"
        let attestationTs = "2026-03-18T20:06:46.776Z"
        let attestationKid = "convos-agents-test"
        let publicKeyBase64url = "xJhoGKv6rsPn58S7VxFPVN8Z6XDerW_nr6UDZ_qjuB4"

        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyBase64url.base64URLDecoded()
        )
        let keyset = MockAgentKeyset(keys: [attestationKid: publicKey])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let referenceDate = try #require(formatter.date(from: attestationTs))

        let result = await AssistantAttestationVerifier.verify(
            inboxId: "wrong-inbox-id",
            attestation: attestation,
            attestationTimestamp: attestationTs,
            kid: attestationKid,
            keyset: keyset,
            referenceDate: referenceDate
        )

        #expect(result == .unverified)
    }

    @Test("Verification returns correct issuer from keyset")
    func issuerResolution() async throws {
        let inboxId = "test-inbox-abc123"
        let attestation = "tVonj7Tfvb0b5D77Pg421DBgWix9dbD-Yj9Y264SuQBzvzSkLYTsThXEZuU2hEiXnpIcnbENmKnhXxIy3jUqDQ"
        let attestationTs = "2026-03-18T20:06:46.776Z"
        let attestationKid = "convos-agents-test"
        let publicKeyBase64url = "xJhoGKv6rsPn58S7VxFPVN8Z6XDerW_nr6UDZ_qjuB4"

        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyBase64url.base64URLDecoded()
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let referenceDate = try #require(formatter.date(from: attestationTs))

        let oauthKeyset = MockAgentKeyset(keys: [attestationKid: publicKey], issuer: .userOAuth)
        let oauthResult = await AssistantAttestationVerifier.verify(
            inboxId: inboxId,
            attestation: attestation,
            attestationTimestamp: attestationTs,
            kid: attestationKid,
            keyset: oauthKeyset,
            referenceDate: referenceDate
        )
        #expect(oauthResult == .verified(.userOAuth))
        #expect(oauthResult.isVerified)
        #expect(oauthResult.isUserOAuthAgent)
        #expect(!oauthResult.isConvosAssistant)
    }

    @Test("CLI JWKS entry parses correctly")
    func cliJwksEntry() {
        let entry = AgentKeysetEntry(
            kid: "convos-agents-test",
            kty: "OKP",
            crv: "Ed25519",
            x: "xJhoGKv6rsPn58S7VxFPVN8Z6XDerW_nr6UDZ_qjuB4",
            use: "sig",
            exp: nil,
            issuer: nil
        )

        #expect(entry.publicKey != nil)
        #expect(entry.publicKey?.rawRepresentation.count == 32)
    }
}
