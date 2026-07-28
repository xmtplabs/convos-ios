import Foundation

/// File-backed last-known abilities catalog, feeding
/// `AbilitiesCatalog.resolving` across process restarts so a launch that
/// lands during an `entitlementsUnavailable` window still renders
/// last-known entitlement state instead of "state unknown".
///
/// Files are scoped per (environment, account scope): the scope is the
/// caller's stable inbox id, so one account's last-known entitlement state
/// can never surface for another account, and a device-only (accountless)
/// catalog is simply never written (callers have no scope to write under).
/// `clearAll()` removes every scope's file on account wipe.
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
    private let directoryURL: URL
    private let environmentName: String

    /// Cache directory under Application Support like the app's other
    /// durable non-database caches.
    public init(environmentName: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(
            directoryURL: base.appendingPathComponent("Abilities", isDirectory: true),
            environmentName: environmentName
        )
    }

    /// Direct directory injection for tests.
    public init(directoryURL: URL, environmentName: String) {
        self.directoryURL = directoryURL
        self.environmentName = environmentName
    }

    public func load(scope: String) -> AbilitiesCatalog? {
        let fileURL = fileURL(scope: scope)
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
            clear(scope: scope)
            return nil
        }
    }

    public func save(_ catalog: AbilitiesCatalog, scope: String) {
        let stored = StoredCatalog(
            catalogVersion: catalog.catalogVersion,
            entitlementsUnavailable: catalog.entitlementsUnavailable,
            abilities: catalog.abilities
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(stored)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(scope: scope), options: .atomic)
        } catch {
            Log.warning("[Abilities] failed to persist catalog cache: \(error.localizedDescription)")
        }
    }

    public func clear(scope: String) {
        try? FileManager.default.removeItem(at: fileURL(scope: scope))
    }

    /// Removes every scope's cache file (account wipe hygiene: leftover
    /// files describe the wiped account's entitlement state).
    public func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// One file per (environment, scope). The scope (an inbox id, hex in
    /// practice) is sanitized to filename-safe characters defensively.
    func fileURL(scope: String) -> URL {
        let safeScope = String(scope.map { (character: Character) -> Character in
            character.isLetter || character.isNumber ? character : "_"
        })
        return directoryURL.appendingPathComponent("catalog-\(environmentName)-\(safeScope).json")
    }

    private struct StoredCatalog: Codable {
        let catalogVersion: Int
        let entitlementsUnavailable: Bool
        let abilities: [AbilitiesAPI.Ability]
    }
}
