import Foundation

/// A summary snapshot of the user's contacts. Emitted by `ContactsDataSource` on start
/// and on `CNContactStoreDidChange` notifications.
///
/// Volume control: address books can be huge (thousands of entries) and most entries are
/// not useful for an agent most of the time. This payload therefore carries *counts* plus
/// a bounded preview of names — never the full database. A richer pull API (lookup by id,
/// search by name) can be layered on top later if agents actually need it.
public struct ContactsPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let totalContactCount: Int
    public let previewContacts: [ContactSummary]
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        totalContactCount: Int,
        previewContacts: [ContactSummary],
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.totalContactCount = totalContactCount
        self.previewContacts = previewContacts
        self.capturedAt = capturedAt
    }
}

public struct ContactSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let givenName: String?
    public let familyName: String?
    public let organization: String?
    public let hasEmail: Bool
    public let hasPhone: Bool

    public init(
        id: String,
        givenName: String?,
        familyName: String?,
        organization: String?,
        hasEmail: Bool,
        hasPhone: Bool
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.hasEmail = hasEmail
        self.hasPhone = hasPhone
    }

    public var displayName: String {
        let parts = [givenName, familyName].compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return organization ?? "(unnamed)"
    }
}
