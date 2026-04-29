import Foundation

/// Stable identifier for a `CapabilityProvider`. Encodes the provider source and the
/// underlying service in a dotted-string form (`device.calendar`,
/// `composio.google_calendar`, etc.).
///
/// Treated as opaque by everything except the provider that owns it; the resolver routes
/// purely by lookup against the registry, never by parsing the raw value.
public struct ProviderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
