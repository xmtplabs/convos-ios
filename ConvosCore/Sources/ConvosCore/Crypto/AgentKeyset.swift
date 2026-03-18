import CryptoKit
import Foundation

public struct AgentKeysetEntry: Codable, Sendable {
    public let kid: String
    public let kty: String
    public let crv: String
    public let x: String
    public let use: String
    public let exp: String?

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
}

public struct AgentKeysetResponse: Codable, Sendable {
    public let keys: [AgentKeysetEntry]
}

public protocol AgentKeysetProviding: Sendable {
    func publicKey(for kid: String) async -> Curve25519.Signing.PublicKey?
    func cachedPublicKey(for kid: String) -> Curve25519.Signing.PublicKey?
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

    // swiftlint:disable:next force_unwrapping
    private static let defaultEndpointURL: URL = URL(string: "https://convos.org/.well-known/agents.json")!

    public init(
        endpointURL: URL = AgentKeyset.defaultEndpointURL,
        fallbackKey: AgentKeysetEntry? = nil,
        urlSession: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.fallbackKey = fallbackKey
        self.urlSession = urlSession
    }

    public func publicKey(for kid: String) async -> Curve25519.Signing.PublicKey? {
        if let key = lookupKey(kid: kid) {
            return key
        }

        await refreshCache()

        if let key = lookupKey(kid: kid) {
            return key
        }

        if let fallbackKey, fallbackKey.kid == kid {
            return fallbackKey.publicKey
        }

        return nil
    }

    nonisolated public func cachedPublicKey(for kid: String) -> Curve25519.Signing.PublicKey? {
        keyCache.get(kid)
    }

    private func lookupKey(kid: String) -> Curve25519.Signing.PublicKey? {
        guard let response = cachedResponse else { return nil }
        guard let entry = response.keys.first(where: { $0.kid == kid }) else { return nil }

        if let expDate = entry.expirationDate, expDate < Date() {
            return nil
        }

        guard let key = entry.publicKey else { return nil }
        keyCache.set(kid, key: key)
        return key
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
                        keyCache.set(entry.kid, key: key)
                    }
                }
            }
        }
    }
}

private final class KeyCache: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var cache: [String: Curve25519.Signing.PublicKey] = [:]

    func get(_ kid: String) -> Curve25519.Signing.PublicKey? {
        lock.lock()
        defer { lock.unlock() }
        return cache[kid]
    }

    func set(_ kid: String, key: Curve25519.Signing.PublicKey) {
        lock.lock()
        defer { lock.unlock() }
        cache[kid] = key
    }
}
