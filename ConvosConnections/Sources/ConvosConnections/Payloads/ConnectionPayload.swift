import Foundation

/// The top-level envelope a `DataSource` emits and a `ConnectionDelivering` transports.
///
/// The envelope itself carries a `schemaVersion` so its shape can evolve. Each body type
/// carries its own `schemaVersion` so individual data sources can iterate independently.
///
/// The serialized form is intentionally `Codable` (JSON) in this package. When the host
/// app wraps the payload in an XMTP content codec it may re-encode to protobuf — the
/// envelope is just a Swift value, and the wire format is the delivery adapter's concern.
public struct ConnectionPayload: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public let schemaVersion: Int
    public let source: ConnectionKind
    public let capturedAt: Date
    public let body: ConnectionPayloadBody

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        source: ConnectionKind,
        capturedAt: Date = Date(),
        body: ConnectionPayloadBody
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.source = source
        self.capturedAt = capturedAt
        self.body = body
    }
}

/// Source-specific payload body. New cases are added as new `DataSource`s are implemented.
///
/// `unknown` preserves forward compatibility when an older build of the app decodes a
/// payload produced by a newer build — the raw bytes round-trip without loss.
public enum ConnectionPayloadBody: Codable, Sendable, Equatable {
    case health(HealthPayload)
    case calendar(CalendarPayload)
    case location(LocationPayload)
    case contacts(ContactsPayload)
    case photos(PhotosPayload)
    case music(MusicPayload)
    case motion(MotionPayload)
    case homeKit(HomePayload)
    case screenTime(ScreenTimePayload)
    case unknown(rawType: String, data: Data)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    private enum BodyType: String, Codable {
        case health
        case calendar
        case location
        case contacts
        case photos
        case music
        case motion
        case homeKit = "home_kit"
        case screenTime = "screen_time"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .health(let payload):
            try container.encode(BodyType.health.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .calendar(let payload):
            try container.encode(BodyType.calendar.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .location(let payload):
            try container.encode(BodyType.location.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .contacts(let payload):
            try container.encode(BodyType.contacts.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .photos(let payload):
            try container.encode(BodyType.photos.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .music(let payload):
            try container.encode(BodyType.music.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .motion(let payload):
            try container.encode(BodyType.motion.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .homeKit(let payload):
            try container.encode(BodyType.homeKit.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case .screenTime(let payload):
            try container.encode(BodyType.screenTime.rawValue, forKey: .type)
            try container.encode(payload, forKey: .data)
        case let .unknown(rawType, data):
            try container.encode(rawType, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch BodyType(rawValue: type) {
        case .health:
            let payload = try container.decode(HealthPayload.self, forKey: .data)
            self = .health(payload)
        case .calendar:
            let payload = try container.decode(CalendarPayload.self, forKey: .data)
            self = .calendar(payload)
        case .location:
            let payload = try container.decode(LocationPayload.self, forKey: .data)
            self = .location(payload)
        case .contacts:
            let payload = try container.decode(ContactsPayload.self, forKey: .data)
            self = .contacts(payload)
        case .photos:
            let payload = try container.decode(PhotosPayload.self, forKey: .data)
            self = .photos(payload)
        case .music:
            let payload = try container.decode(MusicPayload.self, forKey: .data)
            self = .music(payload)
        case .motion:
            let payload = try container.decode(MotionPayload.self, forKey: .data)
            self = .motion(payload)
        case .homeKit:
            let payload = try container.decode(HomePayload.self, forKey: .data)
            self = .homeKit(payload)
        case .screenTime:
            let payload = try container.decode(ScreenTimePayload.self, forKey: .data)
            self = .screenTime(payload)
        case .none:
            let data = try container.decode(Data.self, forKey: .data)
            self = .unknown(rawType: type, data: data)
        }
    }
}

public extension ConnectionPayload {
    /// A short human-readable summary used by the debug view and as a fallback render in chat.
    var summary: String {
        switch body {
        case .health(let payload):
            return payload.summary
        case .calendar(let payload):
            return payload.summary
        case .location(let payload):
            return payload.summary
        case .contacts(let payload):
            return payload.summary
        case .photos(let payload):
            return payload.summary
        case .music(let payload):
            return payload.summary
        case .motion(let payload):
            return payload.summary
        case .homeKit(let payload):
            return payload.summary
        case .screenTime(let payload):
            return payload.summary
        case .unknown(let rawType, _):
            return "Unknown payload (\(rawType))"
        }
    }
}
