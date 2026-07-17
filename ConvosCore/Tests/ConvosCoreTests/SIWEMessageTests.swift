@testable import ConvosCore
import Foundation
import Testing

@Suite("SIWEMessage rendering")
struct SIWEMessageTests {
    @Test("EIP-4361 message renders byte-for-byte against a known fixture (includes Resources)")
    func rendersFixture() {
        // Fixed inputs mirroring the SIWE format Borja requires on the
        // backend: every message carries a `Resources:` block with
        // `convos://device/<deviceId>` so the signature is bound to a
        // specific device, not just the account.
        let issuedAt = isoDate("2026-05-11T12:00:00.000Z")
        let expirationTime = isoDate("2026-05-11T12:05:00.000Z")

        let message = SIWEMessage(
            domain: "convos.app",
            address: "0x1111111111111111111111111111111111111111",
            statement: "Sign in to Convos",
            uri: "https://convos.app",
            chainId: 1,
            nonce: "abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00",
            issuedAt: issuedAt,
            expirationTime: expirationTime,
            resources: ["convos://device/5A2B3C4D-EFAB-1234-5678-90ABCDEF1234"]
        )

        let expected = """
        convos.app wants you to sign in with your Ethereum account:
        0x1111111111111111111111111111111111111111

        Sign in to Convos

        URI: https://convos.app
        Version: 1
        Chain ID: 1
        Nonce: abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00abcdef00
        Issued At: 2026-05-11T12:00:00.000Z
        Expiration Time: 2026-05-11T12:05:00.000Z
        Resources:
        - convos://device/5A2B3C4D-EFAB-1234-5678-90ABCDEF1234
        """

        #expect(message.prepareMessage() == expected)
    }

    @Test("Optional fields are omitted when nil")
    func omitsOptionalsWhenNil() {
        let message = SIWEMessage(
            domain: "example.com",
            address: "0xabc",
            statement: nil,
            uri: "https://example.com",
            chainId: 1,
            nonce: "deadbeef",
            issuedAt: isoDate("2026-01-01T00:00:00.000Z")
        )

        let rendered = message.prepareMessage()
        #expect(!rendered.contains("Expiration Time:"))
        #expect(!rendered.contains("Not Before:"))
        #expect(!rendered.contains("Request ID:"))
        #expect(!rendered.contains("Resources:"))
        // A statement-less message has a single blank line between
        // address and URI block, not the two from the statement case.
        #expect(rendered.contains("0xabc\n\nURI: https://example.com"))
    }
}

private func isoDate(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let d = f.date(from: s) else {
        fatalError("bad ISO date fixture: \(s)")
    }
    return d
}
