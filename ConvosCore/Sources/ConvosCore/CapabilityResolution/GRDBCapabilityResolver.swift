import ConvosConnections
import Foundation
import GRDB

/// GRDB-backed `CapabilityResolver`. Production implementation; pairs with the
/// `capabilityResolution` migration in `SharedDatabaseMigrator`.
public final class GRDBCapabilityResolver: CapabilityResolver, @unchecked Sendable {
    private let database: any DatabaseWriter
    private let registry: any CapabilityProviderRegistry
    private let now: @Sendable () -> Date

    public init(
        database: any DatabaseWriter,
        registry: any CapabilityProviderRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.registry = registry
        self.now = now
    }

    public func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider] {
        await registry.providers(for: subject)
    }

    public func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Set<ProviderID> {
        do {
            return try await database.read { db in
                let row = try DBCapabilityResolution
                    .filter(DBCapabilityResolution.Columns.subject == subject.rawValue)
                    .filter(DBCapabilityResolution.Columns.conversationId == conversationId)
                    .filter(DBCapabilityResolution.Columns.capability == capability.rawValue)
                    .fetchOne(db)
                return Set(
                    row?.providerIds
                        .split(separator: DBCapabilityResolution.providerIdsSeparator, omittingEmptySubsequences: true)
                        .map { ProviderID(rawValue: String($0)) } ?? []
                )
            }
        } catch {
            return []
        }
    }

    public func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {
        try CapabilityResolutionValidator.validate(
            providerIds: providerIds,
            subject: subject,
            capability: capability
        )
        let timestamp = now()
        try await database.write { db in
            let existing = try DBCapabilityResolution
                .filter(DBCapabilityResolution.Columns.subject == subject.rawValue)
                .filter(DBCapabilityResolution.Columns.conversationId == conversationId)
                .filter(DBCapabilityResolution.Columns.capability == capability.rawValue)
                .fetchOne(db)
            let row = DBCapabilityResolution(
                subject: subject,
                conversationId: conversationId,
                capability: capability,
                providerIds: providerIds,
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp
            )
            try row.save(db)
        }
    }

    public func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {
        _ = try await database.write { db in
            try DBCapabilityResolution
                .filter(DBCapabilityResolution.Columns.subject == subject.rawValue)
                .filter(DBCapabilityResolution.Columns.conversationId == conversationId)
                .filter(DBCapabilityResolution.Columns.capability == capability.rawValue)
                .deleteAll(db)
        }
    }

    public func clearAllResolutions(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws {
        _ = try await database.write { db in
            try DBCapabilityResolution
                .filter(DBCapabilityResolution.Columns.subject == subject.rawValue)
                .filter(DBCapabilityResolution.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
    }

    public func removeProviderFromAllResolutions(_ providerId: ProviderID) async throws {
        let timestamp = now()
        try await database.write { db in
            // Read every row, rewrite the ones that reference the provider. Number of rows
            // is bounded by (subjects × conversations × verbs) which stays small.
            let rows = try DBCapabilityResolution.fetchAll(db)
            for row in rows {
                let providers = row.providerIds
                    .split(separator: DBCapabilityResolution.providerIdsSeparator, omittingEmptySubsequences: true)
                    .map(String.init)
                guard providers.contains(providerId.rawValue) else { continue }
                let remaining = providers.filter { $0 != providerId.rawValue }
                if remaining.isEmpty {
                    try row.delete(db)
                } else {
                    let updated = DBCapabilityResolution(
                        subject: row.subject,
                        conversationId: row.conversationId,
                        capability: row.capability,
                        providerIds: remaining.sorted().joined(separator: DBCapabilityResolution.providerIdsSeparator),
                        createdAt: row.createdAt,
                        updatedAt: timestamp
                    )
                    try updated.update(db)
                }
            }
        }
    }
}
