import CryptoSwift
import Foundation

/// EIP-55 mixed-case checksum for Ethereum addresses.
///
/// EIP-4361 (Sign-In With Ethereum) requires the address field to be
/// EIP-55 checksummed. The siwe npm library on the backend rejects
/// non-checksummed addresses with `INVALID_ADDRESS` — which gets
/// surfaced through our wrapper as `InvalidSiweError("parse")` because
/// the SiweMessage constructor throws before we get a chance to look
/// at the specific reason.
///
/// libxmtp's `PublicKey.walletAddress` returns the all-lowercase form,
/// so iOS must checksum locally before putting the address into a SIWE
/// message.
public enum EthereumAddress {
    /// Apply EIP-55 mixed-case checksum to a 20-byte Ethereum address.
    /// Accepts input with or without the `0x` prefix, in any case, and
    /// always returns the `0x` prefix.
    ///
    /// Algorithm (EIP-55):
    ///   - `hash = keccak256(utf8(lowerHex(address)))` over the 40
    ///     hex chars (no `0x`)
    ///   - for each char at index `i`: uppercase the address nibble if
    ///     `hash[i] >= 8` (looking at the i-th hex nibble of the hash)
    public static func toChecksummed(_ address: String) -> String {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard stripped.count == 40 else { return address } // Not a 20-byte address; pass through.
        let lower = stripped.lowercased()
        let hashBytes = SHA3(variant: .keccak256).calculate(for: Array(lower.utf8))

        var out = "0x"
        out.reserveCapacity(42)
        for (index, char) in lower.enumerated() {
            // index-th hex nibble of the hash:
            //   byte at index/2; high nibble for even index, low nibble for odd index
            let byte = hashBytes[index / 2]
            let nibble = index.isMultiple(of: 2) ? (byte >> 4) : (byte & 0x0F)
            if nibble >= 8, char.isLetter {
                out.append(Character(char.uppercased()))
            } else {
                out.append(char)
            }
        }
        return out
    }
}
