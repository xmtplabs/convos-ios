import Foundation

/// File-backed last-known abilities catalog, feeding
/// `AbilitiesCatalog.resolving` across process restarts so a launch that
/// lands during an `entitlementsUnavailable` window still renders
/// last-known entitlement state instead of "state unknown".
///
/// The stored shape is deliberately not `AbilitiesAPI.CatalogResponse`: a
/// merged catalog can carry both the staleness marker and carried-forward
/// entitlement states, a combination the response schema forbids, so the
/// envelope here has no coherence invariant. Per-ability entitlement
/// three-state (object / null / absent) round-trips through
/// `AbilitiesAPI.Ability`'s own Codable.
///
/// Best-effort on both sides: a save failure is logged and dropped (the
/// in-memory last-known state still covers the session), and any load
/// failure reads as "no cache" (the UI then falls back to the state-unknown
/// presentation the availability contract requires).
public struct AbilitiesCatalogDiskCache: Sendable {
    private let fileURL: URL

    /// Cache scoped per environment so dev and local state never bleed into
    /// each other; lives under Application Support like the app's other
    /// durable non-database caches.
    public init(environmentName: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = base
            .appendingPathComponent("Abilities", isDirectory: true)
            .appendingPathComponent("catalog-\(environmentName).json")
    }

    /// Direct file injection for tests.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> AbilitiesCatalog? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let stored = try AbilitiesAPI.wireResponseDecoder().decode(StoredCatalog.self, from: data)
            return AbilitiesCatalog(
                catalogVersion: stored.catalogVersion,
                entitlementsUnavailable: stored.entitlementsUnavailable,
                abilities: stored.abilities
            )
        } catch {
            Log.warning("[Abilities] discarding unreadable catalog cache: \(error.localizedDescription)")
            clear()
            return nil
        }
    }

    public func save(_ catalog: AbilitiesCatalog) {
        let stored = StoredCatalog(
            catalogVersion: catalog.catalogVersion,
            entitlementsUnavailable: catalog.entitlementsUnavailable,
            abilities: catalog.abilities
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(stored)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.warning("[Abilities] failed to persist catalog cache: \(error.localizedDescription)")
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private struct StoredCatalog: Codable {
        let catalogVersion: Int
        let entitlementsUnavailable: Bool
        let abilities: [AbilitiesAPI.Ability]
    }
}
