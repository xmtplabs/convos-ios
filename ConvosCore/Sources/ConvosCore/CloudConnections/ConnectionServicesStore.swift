import Foundation

/// Read-side of the backend-owned connections-picker catalog
/// (`GET /v2/connections/services`): services and their permission bundles.
public protocol ConnectionServicesStoreProtocol: Sendable {
    /// The full catalog, served from cache while fresh.
    func catalog() async throws -> [CloudConnectionsAPI.ServiceConfig]
    /// One service by id (the Composio toolkit slug), or nil when the catalog
    /// has no entry for it.
    func service(id: String) async throws -> CloudConnectionsAPI.ServiceConfig?
    /// Like `service(id:)`, but refetches the catalog when the cached entry is
    /// older than `minimumVersion` — the recovery path for `stale_resource`
    /// replies that name an expected version. Returns whatever the backend
    /// currently serves, even if still older than asked (the caller decides
    /// whether that's fatal).
    func service(id: String, minimumVersion: Int) async throws -> CloudConnectionsAPI.ServiceConfig?
    /// Drops the cached catalog so the next read refetches. Called when the
    /// backend signals staleness out of band (400 `unknown_bundle`).
    func invalidate() async
}

/// In-memory TTL cache over `GET /v2/connections/services`.
///
/// The backend serves the catalog with `Cache-Control: private, max-age=300`;
/// `cacheTTL` mirrors that contract client-side. Entries are version-aware:
/// a consumer that learns a newer `version` exists (stale_resource, or an
/// `unknown_bundle` rejection) can force a refetch via
/// `service(id:minimumVersion:)` / `invalidate()` without waiting out the TTL.
/// Concurrent reads share one in-flight fetch.
public actor ConnectionServicesStore: ConnectionServicesStoreProtocol {
    /// Mirrors the backend's `Cache-Control: private, max-age=300`.
    public static let cacheTTL: TimeInterval = 300

    private let fetchServices: @Sendable () async throws -> CloudConnectionsAPI.ServicesResponse
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    private var cachedServices: [CloudConnectionsAPI.ServiceConfig]?
    private var fetchedAt: Date?
    private var inflight: (generation: Int, task: Task<[CloudConnectionsAPI.ServiceConfig], Error>)?
    /// Bumped by `invalidate()`. A fetch started before the bump still returns
    /// to its original awaiters, but it can no longer populate the cache or be
    /// joined by later reads — otherwise an `unknown_bundle` retry could await
    /// a stale in-flight fetch and re-cache the very catalog the server just
    /// rejected, for another full TTL.
    private var generation: Int = 0

    public init(
        ttl: TimeInterval = ConnectionServicesStore.cacheTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchServices: @escaping @Sendable () async throws -> CloudConnectionsAPI.ServicesResponse
    ) {
        self.ttl = ttl
        self.now = now
        self.fetchServices = fetchServices
    }

    public func catalog() async throws -> [CloudConnectionsAPI.ServiceConfig] {
        if let cachedServices, let fetchedAt, now().timeIntervalSince(fetchedAt) < ttl {
            return cachedServices
        }
        return try await refetch()
    }

    public func service(id: String) async throws -> CloudConnectionsAPI.ServiceConfig? {
        try await catalog().first { $0.id == id }
    }

    public func service(id: String, minimumVersion: Int) async throws -> CloudConnectionsAPI.ServiceConfig? {
        if let cached = try await catalog().first(where: { $0.id == id }), cached.version >= minimumVersion {
            return cached
        }
        return try await refetch().first { $0.id == id }
    }

    public func invalidate() {
        cachedServices = nil
        fetchedAt = nil
        generation += 1
        inflight = nil
    }

    private func refetch() async throws -> [CloudConnectionsAPI.ServiceConfig] {
        if let inflight, inflight.generation == generation {
            return try await inflight.task.value
        }
        let fetchGeneration = generation
        let task = Task { [fetchServices] in
            try await fetchServices().services
        }
        inflight = (fetchGeneration, task)
        defer {
            if inflight?.generation == fetchGeneration {
                inflight = nil
            }
        }
        let services = try await task.value
        if generation == fetchGeneration {
            cachedServices = services
            fetchedAt = now()
        }
        return services
    }
}
