import CryptoSwift
import Foundation
import Testing
@testable import ConvosCore
import XMTPiOS

/// Golden cross-platform test vectors for Linked Device Sync.
///
/// The Android joiner (`convos-client/android`, `core/pairing/`) has to be
/// byte-compatible with this implementation: a slug minted by an iPhone must
/// verify on a Pixel, and the emoji fingerprint both devices render has to
/// match exactly or the user aborts a legitimate pairing.
///
/// `generatePairingVectors` writes `Tests/Fixtures/pairing-vectors.json` from
/// the *real* production code paths (`PairingInvite.signingPayload`,
/// `toURLSafeSlug`, `PairingCoordinator.emojiFingerprint`, the four codecs).
/// That file is committed into both repos; Android's `commonTest` pins every
/// interop assertion against it.
///
/// `iosStillMatchesCommittedVectors` is the guard in the other direction: any
/// future iOS change that would break the Android joiner fails here first.
@Suite("Pairing interop vectors")
struct PairingInteropVectorsTests {
    // MARK: - Fixed inputs (never change these; Android pins them)

    /// Same convention as `SIWESignerTests` — a fixed key so the vectors are
    /// reproducible.
    private static let privateKeyBytes: Data = Data(repeating: 0x11, count: 32)

    /// Opaque to the wire protocol: the inbox id is carried as a UTF-8 string
    /// in the signing payload and hashed as a string in the fingerprint, so a
    /// fixed literal exercises the same bytes a real libxmtp inbox id would
    /// (deriving one needs the FFI's `generateInboxId`, which isn't reachable
    /// from this test target).
    private static let initiatorInboxId: String =
        "3f9a1c0e5b7d2846a1f30c9e4d8b6752e0a4c9137fb5628d0e3a7c14b9d5f682"
    private static let joinerInboxId: String =
        "8c2d40b6e1f97a35c0d82b4e6f19a7d35c0e28b4f6a19d73c58e02b4f6a19d73"

    private static let nonce: Data = Data((0 ..< 16).map { UInt8($0 &* 17) })
    private static let issuedAt: Int64 = 1_750_000_000
    private static let expiresAt: Int64 = 1_750_000_120
    private static let pin: String = "123456"

    /// Standalone EIP-191 messages, so the Android `Eip191` + secp256k1
    /// recovery work can be pinned before any pairing types exist. The
    /// non-ASCII case is deliberate: the prefix length is the message's
    /// **UTF-8 byte count**, which differs from Kotlin's `String.length`
    /// (UTF-16 units) for anything outside the BMP-ASCII range.
    private static let eip191Messages: [String] = [
        "",
        "Hello, Convos!",
        "héllo 🌍 wörld",
    ]

    private static let identityShareKey: Data = Data(repeating: 0x22, count: 32)
    private static let identityShareIssuedAt: Int64 = 1_750_000_100
    private static let deviceRemovedAt: Int64 = 1_750_000_200

    // MARK: - Generation

    @Test("Generate pairing-vectors.json from the production code paths")
    func generatePairingVectors() async throws {
        let vectors = try await Self.buildVectors()
        let json = try JSONSerialization.data(
            withJSONObject: vectors,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let url = Self.fixtureURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: url)
        print("[pairing-vectors] wrote \(json.count) bytes to \(url.path)")
    }

    // MARK: - Mirror assertion (drift guard)

    @Test("iOS still produces and accepts the committed vectors")
    func iosStillMatchesCommittedVectors() async throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        guard let committed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("pairing-vectors.json is not a JSON object")
            return
        }

        // 0. EIP-191 digests and signatures still recover the same address.
        let identity = try #require(committed["identity"] as? [String: Any])
        let address = try #require(identity["address"] as? String)
        for vector in try #require(committed["eip191"] as? [[String: Any]]) {
            let message = try #require(vector["message"] as? String)
            #expect(Self.hex(Self.personalSignDigest(message)) == vector["digestHex"] as? String)
            let signature = try #require((vector["signatureBase64"] as? String).flatMap {
                Data(base64Encoded: $0)
            })
            let recovered = try EthereumSignatureRecovery.recoverAddress(
                message: message,
                signature: signature
            )
            #expect(recovered == address.lowercased())
        }

        // 1. Signing payload bytes are unchanged.
        let invite = try #require(committed["invite"] as? [String: Any])
        let payload = PairingInvite.signingPayload(
            initiatorInboxId: Self.initiatorInboxId,
            initiatorAddress: try #require(invite["initiatorAddress"] as? String),
            nonce: Self.nonce,
            issuedAt: Self.issuedAt,
            expiresAt: Self.expiresAt
        )
        #expect(Self.hex(payload) == invite["signingPayloadHex"] as? String)
        // The interop trap: the signed *message* is the lowercase hex string
        // of the payload, not the payload bytes.
        #expect(invite["signedMessage"] as? String == Self.hex(payload))

        // 2. The committed slug still decodes and its signature still verifies.
        let slug = try #require(invite["slug"] as? String)
        let decoded = try #require(Self.base64URLDecode(slug))
        let parsed = try JSONDecoder().decode(PairingInvite.self, from: decoded)
        #expect(parsed.initiatorInboxId == Self.initiatorInboxId)
        #expect(parsed.nonce == Self.nonce)
        #expect(parsed.issuedAt == Self.issuedAt)
        #expect(parsed.expiresAt == Self.expiresAt)
        #expect(parsed.signature.count == 65)
        // Deliberately not `fromURLSafeSlug` — that enforces expiry and the
        // fixture's window is long past.
        try parsed.verifySignature()

        // 3. Emoji pool and fingerprints are unchanged.
        let emoji = try #require(committed["emoji"] as? [String: Any])
        #expect(emoji["poolCount"] as? Int == EmojiSelector.emojis.count)
        #expect(emoji["pool"] as? [String] == EmojiSelector.emojis)
        for testCase in try #require(emoji["cases"] as? [[String: Any]]) {
            let produced = PairingCoordinator.emojiFingerprint(
                inboxA: try #require(testCase["inboxA"] as? String),
                inboxB: try #require(testCase["inboxB"] as? String),
                pin: try #require(testCase["pin"] as? String)
            )
            #expect(produced == testCase["emojis"] as? [String])
        }

        // 4. Every codec still decodes its committed bytes back to the same
        //    content.
        //
        //    Deliberately not a byte comparison of re-encoded output:
        //    Swift's `JSONEncoder` emits object keys in a per-process
        //    randomized order, so the committed bytes are only one of many
        //    valid encodings. Decoding is the property that actually has to
        //    hold cross-platform — Android's encoder orders keys differently
        //    again, and both sides must accept either.
        let codecs = try #require(committed["codecs"] as? [String: Any])
        func contentBytes(_ key: String) throws -> Data {
            let vector = try #require(codecs[key] as? [String: Any])
            return try #require((vector["contentBase64"] as? String).flatMap { Data(base64Encoded: $0) })
        }
        func encoded(_ key: String, _ type: ContentTypeID) throws -> EncodedContent {
            var encoded = EncodedContent()
            encoded.type = type
            encoded.content = try contentBytes(key)
            return encoded
        }

        let joinRequest = try PairingJoinRequestCodec().decode(
            content: encoded("pairing_join_request", ContentTypePairingJoinRequest)
        )
        #expect(joinRequest.schemaVersion == 1)
        #expect(joinRequest.slug == slug)
        #expect(joinRequest.joinerInboxId == Self.joinerInboxId)
        #expect(joinRequest.deviceName == "Pixel 9 Pro")

        let pinMessage = try PairingMessageCodec().decode(
            content: encoded("pairing_message_pin", ContentTypePairingMessage)
        )
        #expect(pinMessage == .pin(Self.pin))
        let pinEcho = try PairingMessageCodec().decode(
            content: encoded("pairing_message_pin_echo", ContentTypePairingMessage)
        )
        #expect(pinEcho == .pinEcho(Self.pin))
        #expect(pinEcho.type.rawValue == "pin_echo")
        let errorMessage = try PairingMessageCodec().decode(
            content: encoded("pairing_message_error", ContentTypePairingMessage)
        )
        #expect(errorMessage == .error("Pairing failed"))

        let identityShare = try IdentityShareCodec().decode(
            content: encoded("identity_share", ContentTypeIdentityShare)
        )
        #expect(identityShare.schemaVersion == 1)
        #expect(identityShare.privateKeyData == Self.identityShareKey)
        #expect(identityShare.inboxId == Self.initiatorInboxId)
        #expect(identityShare.issuedAt == Self.identityShareIssuedAt)
        #expect(identityShare.initiatorDeviceName == "Cameron's iPhone")
        #expect(identityShare.displayName == "Cameron")
        #expect(identityShare.imageAssetIdentifier == "https://assets.convos.org/avatar/abc123.jpg")

        let deviceRemoved = try DeviceRemovedCodec().decode(
            content: encoded("device_removed", ContentTypeDeviceRemoved)
        )
        #expect(deviceRemoved.schemaVersion == 1)
        #expect(deviceRemoved.revokedInstallationId == "b1946ac92492d2347c6235b4d2611184")
        #expect(deviceRemoved.removedAt == Self.deviceRemovedAt)
    }

    // MARK: - Builders

    private static func buildVectors() async throws -> [String: Any] {
        let privateKey = try PrivateKey(privateKeyBytes)
        let address = privateKey.walletAddress

        let payload = PairingInvite.signingPayload(
            initiatorInboxId: initiatorInboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let signedMessage = hex(payload)
        let signature = try await privateKey.sign(signedMessage)
        let invite = PairingInvite(
            initiatorInboxId: initiatorInboxId,
            initiatorAddress: address,
            nonce: nonce,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: signature.rawData
        )
        // Closes the loop on our local hex helper: if it disagreed with the
        // production `toHexString()` that `verifySignature` re-derives, this
        // would throw.
        try invite.verifySignature()
        let slug = try invite.toURLSafeSlug()

        return [
            "schema": 1,
            "generatedBy": "ConvosCore PairingInteropVectorsTests",
            "eip191": try await eip191Vectors(privateKey: privateKey),
            "note": "Golden cross-platform vectors for Linked Device Sync. "
                + "Regenerate with: swift test --package-path ConvosCore --filter generatePairingVectors. "
                + "JSON object key order (in `slug` and every `contentBase64`) is whatever Swift's "
                + "JSONEncoder emitted — it is randomized per process and is NOT part of the contract. "
                + "Consumers must decode order-insensitively and tolerate unknown keys.",
            "identity": [
                "privateKeyHex": hex(privateKeyBytes),
                "address": address,
                "addressLowercased": address.lowercased(),
                "inboxId": initiatorInboxId,
            ],
            "invite": [
                "schemaVersion": 1,
                "initiatorInboxId": initiatorInboxId,
                "initiatorAddress": address,
                "nonceBase64": nonce.base64EncodedString(),
                "nonceHex": hex(nonce),
                "issuedAt": issuedAt,
                "expiresAt": expiresAt,
                "signingPayloadHex": hex(payload),
                "signedMessage": signedMessage,
                "signatureBase64": signature.rawData.base64EncodedString(),
                "signatureHex": hex(signature.rawData),
                "signatureRecoveryByte": Int(signature.rawData[64]),
                "slug": slug,
                "verifyAtUnixSeconds": issuedAt + 1,
            ],
            "emoji": [
                "poolCount": EmojiSelector.emojis.count,
                "pool": EmojiSelector.emojis,
                "cases": [
                    emojiCase(inboxA: initiatorInboxId, inboxB: joinerInboxId, pin: pin),
                    // Same pair, arguments swapped: the fingerprint sorts its
                    // inputs, so Android must produce the identical triple.
                    emojiCase(inboxA: joinerInboxId, inboxB: initiatorInboxId, pin: pin),
                    emojiCase(inboxA: "alpha", inboxB: "bravo", pin: "000000"),
                    emojiCase(inboxA: "alpha", inboxB: "bravo", pin: "999999"),
                ],
            ],
            "pin": [
                "raw": pin,
                "formatted": PairingCoordinator.formatPin(pin),
            ],
            "codecs": try codecVectors(slug: slug),
        ]
    }

    private static func eip191Vectors(privateKey: PrivateKey) async throws -> [[String: Any]] {
        var vectors: [[String: Any]] = []
        for message in eip191Messages {
            let signature = try await privateKey.sign(message)
            vectors.append([
                "message": message,
                "messageUtf8ByteCount": Array(message.utf8).count,
                "digestHex": hex(personalSignDigest(message)),
                "signatureHex": hex(signature.rawData),
                "signatureBase64": signature.rawData.base64EncodedString(),
                "recoveryByte": Int(signature.rawData[64]),
                "recoveredAddress": try EthereumSignatureRecovery.recoverAddress(
                    message: message,
                    signature: signature.rawData
                ),
            ])
        }
        return vectors
    }

    /// Mirror of `EthereumSignatureRecovery.personalSignDigest` (which is
    /// private). Verified against it indirectly: `recoverAddress` re-derives
    /// the digest and must recover the same address we record.
    private static func personalSignDigest(_ message: String) -> Data {
        let utf8 = Array(message.utf8)
        var bytes: [UInt8] = Array("\u{19}Ethereum Signed Message:\n\(utf8.count)".utf8)
        bytes.append(contentsOf: utf8)
        return Data(SHA3(variant: .keccak256).calculate(for: bytes))
    }

    private static func emojiCase(inboxA: String, inboxB: String, pin: String) -> [String: Any] {
        [
            "inboxA": inboxA,
            "inboxB": inboxB,
            "pin": pin,
            "emojis": PairingCoordinator.emojiFingerprint(inboxA: inboxA, inboxB: inboxB, pin: pin),
        ]
    }

    private static func codecVectors(slug: String) throws -> [String: Any] {
        let joinRequest = try PairingJoinRequestCodec().encode(
            content: PairingJoinRequestContent(
                slug: slug,
                joinerInboxId: joinerInboxId,
                deviceName: "Pixel 9 Pro"
            )
        )
        let pinMessage = try PairingMessageCodec().encode(content: .pin(pin))
        let pinEcho = try PairingMessageCodec().encode(content: .pinEcho(pin))
        let errorMessage = try PairingMessageCodec().encode(content: .error("Pairing failed"))
        let identityShare = try IdentityShareCodec().encode(
            content: IdentityShareContent(
                privateKeyData: identityShareKey,
                inboxId: initiatorInboxId,
                issuedAt: identityShareIssuedAt,
                initiatorDeviceName: "Cameron's iPhone",
                displayName: "Cameron",
                imageAssetIdentifier: "https://assets.convos.org/avatar/abc123.jpg"
            )
        )
        let deviceRemoved = try DeviceRemovedCodec().encode(
            content: DeviceRemovedContent(
                revokedInstallationId: "b1946ac92492d2347c6235b4d2611184",
                removedAt: deviceRemovedAt
            )
        )
        return [
            "pairing_join_request": describe(joinRequest),
            "pairing_message_pin": describe(pinMessage),
            "pairing_message_pin_echo": describe(pinEcho),
            "pairing_message_error": describe(errorMessage),
            "identity_share": describe(identityShare),
            "device_removed": describe(deviceRemoved),
        ]
    }

    private static func describe(_ encoded: EncodedContent) -> [String: Any] {
        [
            "authorityId": encoded.type.authorityID,
            "typeId": encoded.type.typeID,
            "versionMajor": Int(encoded.type.versionMajor),
            "versionMinor": Int(encoded.type.versionMinor),
            "contentType": "\(encoded.type.authorityID)/\(encoded.type.typeID):"
                + "\(encoded.type.versionMajor).\(encoded.type.versionMinor)",
            "contentBase64": encoded.content.base64EncodedString(),
            "contentJSON": String(data: encoded.content, encoding: .utf8) ?? "",
        ]
    }

    // MARK: - Helpers

    /// `Tests/Fixtures/pairing-vectors.json`, resolved from this file's own
    /// location so the test works from any working directory.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConvosCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("pairing-vectors.json")
    }

    /// Lowercase, unprefixed — the same shape `Data.toHexString()` produces.
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URLDecode(_ slug: String) -> Data? {
        var padded = slug
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }
}
