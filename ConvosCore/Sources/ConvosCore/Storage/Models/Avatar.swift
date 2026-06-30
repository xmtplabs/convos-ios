import Foundation

/// A resolved avatar reference, collapsing the scattered
/// url/salt/nonce/key fields into one value. `plain` is a bare URL needing no
/// decryption; `encrypted` carries the AES-256-GCM material to decrypt the
/// ciphertext at `url`.
///
/// Use `from(...)` to construct from optional fields: it returns nil for an
/// absent/empty URL, `.encrypted` only when all crypto fields are present and
/// correctly sized (salt 32, nonce 12, key 32), and `.plain` otherwise. This
/// removes the "four optional fields, three of which must agree" handling from
/// callers.
///
/// Not wired into rendering yet; introduced ahead of the `ProfilesRepository`
/// and the avatar surfaces that will consume it.
enum Avatar: Hashable, Sendable {
    case plain(url: String, updatedAt: Date)
    case encrypted(url: String, salt: Data, nonce: Data, key: Data, updatedAt: Date)

    static func from(
        url: String?,
        salt: Data?,
        nonce: Data?,
        key: Data?,
        updatedAt: Date
    ) -> Avatar? {
        guard let url, !url.isEmpty else {
            return nil
        }
        if let salt, let nonce, let key,
           salt.count == Constant.saltByteCount,
           nonce.count == Constant.nonceByteCount,
           key.count == Constant.keyByteCount {
            return .encrypted(url: url, salt: salt, nonce: nonce, key: key, updatedAt: updatedAt)
        }
        return .plain(url: url, updatedAt: updatedAt)
    }

    var url: String {
        switch self {
        case let .plain(url, _):
            return url
        case let .encrypted(url, _, _, _, _):
            return url
        }
    }

    var updatedAt: Date {
        switch self {
        case let .plain(_, updatedAt):
            return updatedAt
        case let .encrypted(_, _, _, _, updatedAt):
            return updatedAt
        }
    }

    var isEncrypted: Bool {
        switch self {
        case .plain:
            return false
        case .encrypted:
            return true
        }
    }

    private enum Constant {
        static let saltByteCount: Int = 32
        static let nonceByteCount: Int = 12
        static let keyByteCount: Int = 32
    }
}
