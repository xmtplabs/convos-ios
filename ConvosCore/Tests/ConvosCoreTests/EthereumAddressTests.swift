@testable import ConvosCore
import Testing

/// EIP-55 checksum vectors from the spec
/// (https://eips.ethereum.org/EIPS/eip-55#test-cases). Without these
/// the backend's `siwe` lib rejects the SIWE message with
/// `INVALID_ADDRESS`, which our `verifySiwe` wrapper labels generically
/// as `InvalidSiweError("parse")` — easy to misdiagnose, hence the
/// canary here.
@Suite("EthereumAddress EIP-55 checksum")
struct EthereumAddressTests {
    @Test("Canonical EIP-55 vectors from the spec round-trip")
    func eip55Vectors() {
        let vectors: [String] = [
            // All caps
            "0x52908400098527886E0F7030069857D2E4169EE7",
            "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
            // All Lower
            "0xde709f2102306220921060314715629080e2fb77",
            "0x27b1fdb04752bbc536007a920d24acb045561c26",
            // Normal
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ]
        for vector in vectors {
            #expect(EthereumAddress.toChecksummed(vector.lowercased()) == vector)
            #expect(EthereumAddress.toChecksummed(vector.uppercased().replacingOccurrences(of: "0X", with: "0x")) == vector)
            #expect(EthereumAddress.toChecksummed(vector) == vector) // idempotent
        }
    }

    @Test("Strips 0x prefix and re-adds it in output")
    func handlesMissingPrefix() {
        let lower = "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        let expected = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        #expect(EthereumAddress.toChecksummed(lower) == expected)
    }

    @Test("Non-20-byte input passes through unchanged")
    func tooShortPassthrough() {
        #expect(EthereumAddress.toChecksummed("0xabcd") == "0xabcd")
        #expect(EthereumAddress.toChecksummed("").isEmpty)
    }
}
