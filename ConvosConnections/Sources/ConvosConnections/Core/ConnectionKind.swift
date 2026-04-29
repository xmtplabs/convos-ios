import Foundation

/// Identifies a native iOS data source that Convos can pull data from.
///
/// A new case is added whenever a new `DataSource` implementation is written.
/// The raw value is used as the discriminator in persisted enablement state and in
/// the `ConnectionPayload` envelope — changing a raw value is a breaking change.
public enum ConnectionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case health
    case calendar
    case contacts
    case location
    case photos
    case music
    case homeKit = "home_kit"
    case screenTime = "screen_time"
    case motion
}

public extension ConnectionKind {
    var displayName: String {
        switch self {
        case .health: return "Health"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .location: return "Location"
        case .photos: return "Photos"
        case .music: return "Music"
        case .homeKit: return "Home"
        case .screenTime: return "Screen Time"
        case .motion: return "Motion & Activity"
        }
    }

    var systemImageName: String {
        switch self {
        case .health: return "heart.fill"
        case .calendar: return "calendar"
        case .contacts: return "person.2.fill"
        case .location: return "location.fill"
        case .photos: return "photo.stack.fill"
        case .music: return "music.note"
        case .homeKit: return "house.fill"
        case .screenTime: return "hourglass"
        case .motion: return "figure.walk"
        }
    }
}
