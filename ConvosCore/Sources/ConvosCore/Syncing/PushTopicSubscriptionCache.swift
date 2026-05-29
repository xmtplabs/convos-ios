import CryptoKit
import Foundation

/// Hash debounce cache for `PushTopicSubscriptionManager.reconcilePushTopics`.
/// Lives in UserDefaults so the cache survives app launches without holding
/// the actor (which would burn an extra memory copy of the topic set on every
/// process).
///
/// Cache key partitions by `(inboxId, clientId, deviceId, pushTokenSha256)`
/// so the four invalidation paths the plan calls out fall out naturally:
///
/// - APNS token rotation: `pushTokenSha256` changes -> different key -> miss.
/// - Identity rotation (sign-out/in as a new account): `inboxId` / `clientId`
///   change -> different key -> miss. Stale entries for the previous identity
///   stay in UserDefaults but are functionally inert (no key in any future
///   lookup will match them) and get reaped by ``clearAll()`` when the caller
///   explicitly wants a clean slate.
/// - Device-id rotation: `deviceId` changes -> different key -> miss.
/// - Topic set change: the value (topic-set hash) differs from the cached one
///   -> miss.
///
/// Writes only happen inside `subscribe`'s success branch in
/// `PushTopicSubscriptionManager`. A thrown API call leaves the cache
/// un-mutated so the next reconcile retries the wire. The "HTTP 200 but
/// remote-apply skipped" state that Stack 2's response shape will surface
/// (D16: `remoteApplied: false`) is not handled yet. Until that field
/// ships, iOS trusts a successful URLSession round trip.
final class PushTopicSubscriptionCache: @unchecked Sendable {
    private static let storeKey: String = "convos.pushTopicSubscriptionCache.v1"

    private let userDefaults: UserDefaults
    private let lock: NSLock = .init()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Looks up the cached topic-set hash for the supplied key.
    /// Returns nil on first call, after a successful failure that left no
    /// cache write, or whenever the caller passes a fresh `(identity, token,
    /// device)` tuple.
    func lookupHash(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return readDict()[key]
    }

    /// Stores the topic-set hash. Callers MUST only invoke this from inside
    /// `subscribe`'s success branch; writing pessimistically (before the API
    /// call returns) would leave iOS thinking it's synced after a transient
    /// failure, silently breaking the retry loop the plan exists to enable.
    func storeHash(_ hash: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = readDict()
        dict[key] = hash
        userDefaults.set(dict, forKey: Self.storeKey)
    }

    /// Clears every cached hash. Intended for explicit "wipe my state"
    /// operations like sign-out, "Delete all data", or test setup. Day-to-day
    /// identity rotation is handled by key partitioning above and does NOT
    /// need to call this.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: Self.storeKey)
    }

    private func readDict() -> [String: String] {
        userDefaults.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }
}

/// Components of the cache key, kept here so the same canonicalization is
/// used at write-time (inside subscribe's success branch) and lookup-time
/// (top of reconcile).
///
/// The plan (D8) lists `environment + accountId + apnsEnv` as separate
/// components. We don't need them as explicit fields because they are all
/// functionally encoded by `inboxId`:
/// - Each build environment (Dev / Local / Prod) uses a distinct keychain
///   access group, so the inbox set is partitioned per environment. A user
///   reinstalling across builds gets a fresh inboxId.
/// - `accountId` -> `inboxId` is 1:1 (one XMTP inbox per account).
/// - `apnsEnv` is constant per build (sandbox on non-prod, production on
///   prod), so it never varies independently of the environment.
/// Adding them as separate fields would be redundant; the partition is the
/// same. If the build environments ever start sharing keychain groups,
/// revisit this.
struct PushTopicCacheKey: Sendable {
    let inboxId: String
    let clientId: String
    let deviceId: String
    let pushTokenSha256: String

    var keyString: String {
        "\(inboxId)|\(clientId)|\(deviceId)|\(pushTokenSha256)"
    }
}

/// Canonical hashing routine shared by the iOS cache and the Stack 2
/// backend snapshot. Topics are sorted lexicographically as UTF-8 strings,
/// joined with a single LF separator, and run through SHA-256 with lowercase
/// hex output.
///
/// Cross-stack pin (Stack 2 T19): backend implementation lives at
/// `convos-backend/src/notifications/hash.ts`. If you change either side,
/// change BOTH, and add a matching test on the OTHER side proving the
/// same input still produces the same output. Stack 2 tests for the backend
/// helper:
///   - `convos-backend/tests/notifications-hash.test.ts`: 11 cases pinning
///     sorted, LF separator, SHA-256 hex lowercase, sentinel for no-token.
/// Stack 2 idempotency depends on these two staying in sync byte-for-byte.
enum PushTopicHash {
    static func of(_ topics: [String]) -> String {
        let canonical = topics.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the APNS token bytes, lowercase hex. Returns the literal
    /// sentinel `"none"` when no token is available yet so cache keys still
    /// partition cleanly between the pre-token and post-token states (and so
    /// the first real token after cold launch always produces a cache miss
    /// and a fresh reconcile).
    static func ofToken(_ token: String?) -> String {
        guard let token = token, !token.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
