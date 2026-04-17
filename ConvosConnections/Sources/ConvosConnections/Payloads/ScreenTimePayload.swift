import Foundation

/// Surface state for the Screen Time / Family Controls connection.
///
/// Unlike other sources, this payload does **not** carry actual usage data — Apple isolates
/// Screen Time data in a separate process and only exposes it through `DeviceActivityReport`
/// views rendered in a host-app extension. Surfacing numeric usage (hours in apps,
/// categories, etc.) to conversations would require a sibling `DeviceActivityMonitor`
/// extension target, which is outside the package's scope.
///
/// What the payload *does* carry is the authorization state plus the user's
/// `FamilyActivitySelection` — i.e. which apps / categories they've explicitly opted into
/// sharing context about. That selection is what a future extension would monitor.
public struct ScreenTimePayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let authorized: Bool
    public let selectedApplicationCount: Int
    public let selectedCategoryCount: Int
    public let selectedWebDomainCount: Int
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        authorized: Bool,
        selectedApplicationCount: Int = 0,
        selectedCategoryCount: Int = 0,
        selectedWebDomainCount: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.authorized = authorized
        self.selectedApplicationCount = selectedApplicationCount
        self.selectedCategoryCount = selectedCategoryCount
        self.selectedWebDomainCount = selectedWebDomainCount
        self.capturedAt = capturedAt
    }
}
