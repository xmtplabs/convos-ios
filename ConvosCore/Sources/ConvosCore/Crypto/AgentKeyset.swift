import CryptoKit
import Foundation

public struct AgentKeysetEntry: Codable, Sendable {
    public let kid: String
    public let kty: String
    public let crv: String
    public let x: String
    public let use: String
    public let exp: String?
    public let issuer: String?

    public var publicKey: Curve25519.Signing.PublicKey? {
        guard kty == "OKP", crv == "Ed25519",
              let keyData = try? x.base64URLDecoded() else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    }

    public var expirationDate: Date? {
        guard let exp else { return nil }
        return ISO8601DateFormatter().date(from: exp)
    }

    public var resolvedIssuer: AgentVerification.Issuer {
        AgentVerification.Issuer(rawValue: issuer ?? "") ?? .unknown
    }
}

public struct AgentKeysetResponse: Codable, Sendable {
    public let keys: [AgentKeysetEntry]
}

public struct ResolvedKey: Sendable {
    public let publicKey: Curve25519.Signing.PublicKey
    public let issuer: AgentVerification.Issuer

    public init(publicKey: Curve25519.Signing.PublicKey, issuer: AgentVerification.Issuer) {
        self.publicKey = publicKey
        self.issuer = issuer
    }
}

public protocol AgentKeysetProviding: Sendable {
    func resolveKey(for kid: String) async -> ResolvedKey?
    func cachedResolveKey(for kid: String) -> ResolvedKey?
}

public final class AgentKeysetStore: @unchecked Sendable {
    public static let instance: AgentKeysetStore = .init()

    private let lock: NSLock = .init()
    private var _shared: (any AgentKeysetProviding)?

    public var shared: (any AgentKeysetProviding)? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    public func configure(_ keyset: any AgentKeysetProviding) {
        lock.lock()
        defer { lock.unlock() }
        _shared = keyset
    }
}

public actor AgentKeyset: AgentKeysetProviding {
    private var cachedResponse: AgentKeysetResponse?
    private var lastFetchDate: Date?
    private var fetchTask: Task<AgentKeysetResponse?, Never>?
    private let endpointURL: URL
    private let fallbackKey: AgentKeysetEntry?
    private let urlSession: URLSession
    nonisolated private let keyCache: KeyCache = .init()

    private static let cacheDuration: TimeInterval = 86400

    public static func endpointURL(for environment: AppEnvironment) -> URL {
        let apiBase = environment.apiBaseURL
        let domainBase = apiBase.hasSuffix("/api")
            ? String(apiBase.dropLast(4))
            : apiBase
        // swiftlint:disable:next force_unwrapping
        return URL(string: "\(domainBase)/.well-known/agents.json")!
    }

    public init(
        endpointURL: URL,
        fallbackKey: AgentKeysetEntry? = nil,
        urlSession: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.fallbackKey = fallbackKey
        self.urlSession = urlSession
    }

    public func resolveKey(for kid: String) async -> ResolvedKey? {
        if let resolved = lookupKey(kid: kid) {
            return resolved
        }

        await refreshCache()

        if let resolved = lookupKey(kid: kid) {
            return resolved
        }

        if let fallbackKey, fallbackKey.kid == kid, let key = fallbackKey.publicKey {
            return ResolvedKey(publicKey: key, issuer: fallbackKey.resolvedIssuer)
        }

        return nil
    }

    nonisolated public func cachedResolveKey(for kid: String) -> ResolvedKey? {
        keyCache.get(kid)
    }

    private func lookupKey(kid: String) -> ResolvedKey? {
        guard let response = cachedResponse else { return nil }
        guard let entry = response.keys.first(where: { $0.kid == kid }) else { return nil }

        if let expDate = entry.expirationDate, expDate < Date() {
            return nil
        }

        guard let key = entry.publicKey else { return nil }
        let resolved = ResolvedKey(publicKey: key, issuer: entry.resolvedIssuer)
        keyCache.set(kid, resolved: resolved)
        return resolved
    }

    public func prefetch() async {
        await refreshCache()
    }

    private func refreshCache() async {
        if let lastFetch = lastFetchDate,
           Date().timeIntervalSince(lastFetch) < Self.cacheDuration,
           cachedResponse != nil {
            return
        }

        if let existingTask = fetchTask {
            _ = await existingTask.value
            return
        }

        let task = Task<AgentKeysetResponse?, Never> { [endpointURL, urlSession] in
            do {
                let (data, _) = try await urlSession.data(from: endpointURL)
                return try JSONDecoder().decode(AgentKeysetResponse.self, from: data)
            } catch {
                return nil
            }
        }

        fetchTask = task
        let result = await task.value
        fetchTask = nil

        if let result {
            cachedResponse = result
            lastFetchDate = Date()
            for entry in result.keys {
                if let key = entry.publicKey {
                    let isExpired = entry.expirationDate.map { $0 < Date() } ?? false
                    if !isExpired {
                        keyCache.set(entry.kid, resolved: ResolvedKey(publicKey: key, issuer: entry.resolvedIssuer))
                    }
                }
            }
        }
    }
}

private final class KeyCache: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var cache: [String: ResolvedKey] = [:]

    func get(_ kid: String) -> ResolvedKey? {
        lock.lock()
        defer { lock.unlock() }
        return cache[kid]
    }

    func set(_ kid: String, resolved: ResolvedKey) {
        lock.lock()
        defer { lock.unlock() }
        cache[kid] = resolved
    }
}
