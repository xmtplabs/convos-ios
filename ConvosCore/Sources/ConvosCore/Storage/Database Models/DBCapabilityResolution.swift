import ConvosConnections
import Foundation
import GRDB

/// Persistence row for `CapabilityResolution`. The set of providers is stored as a
/// comma-joined string so the same schema can hold both single-provider rows (the common
/// case) and federated-read rows (currently only `.fitness`).
///
/// Cardinality is enforced in `CapabilityResolutionValidator`, not the schema — that
/// keeps the on-disk shape stable when more subjects opt into federation.
struct DBCapabilityResolution: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "capabilityResolution"

    enum Columns {
        static let subject: Column = Column(CodingKeys.subject)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let capability: Column = Column(CodingKeys.capability)
        static let providerIds: Column = Column(CodingKeys.providerIds)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let subject: String
    let conversationId: String
    let capability: String
    let providerIds: String
    let createdAt: Date
    let updatedAt: Date
}

extension DBCapabilityResolution {
    /// Provider id list separator. Comma is safe because `ProviderID.rawValue` is dotted-
    /// alphanumeric ("device.calendar", "composio.google_calendar") with no commas.
    static let providerIdsSeparator: String = ","

    init(
        subject: CapabilitySubject,
        conversationId: String,
        capability: ConnectionCapability,
        providerIds: Set<ProviderID>,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.subject = subject.rawValue
        self.conversationId = conversationId
        self.capability = capability.rawValue
        // Sort for stable on-disk representation; resolver consumers treat it as a Set.
        self.providerIds = providerIds
            .map(\.rawValue)
            .sorted()
            .joined(separator: Self.providerIdsSeparator)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func toResolution() -> CapabilityResolution? {
        guard let subjectValue = CapabilitySubject(rawValue: subject),
              let capabilityValue = ConnectionCapability(rawValue: capability) else {
            return nil
        }
        let providers = providerIds
            .split(separator: Self.providerIdsSeparator, omittingEmptySubsequences: true)
            .map { ProviderID(rawValue: String($0)) }
        return CapabilityResolution(
            subject: subjectValue,
            conversationId: conversationId,
            capability: capabilityValue,
            providerIds: Set(providers)
        )
    }
}
