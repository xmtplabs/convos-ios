import Foundation

/// What an agent is asking for. Stable, user-facing, provider-independent.
///
/// Subjects are deliberately separate from `ConnectionKind` (which describes device-side
/// providers only) — not all subjects have a device counterpart (`.tasks`, `.mail`), and
/// not all `ConnectionKind` values map cleanly to a user-facing subject (`.motion`).
public enum CapabilitySubject: String, Hashable, Sendable, Codable, CaseIterable {
    case calendar
    case contacts
    case tasks
    case mail
    case photos
    case fitness
    case music
    case location
    case home
    case screenTime = "screen_time"
}

public extension CapabilitySubject {
    /// Whether `.read` invocations on this subject can resolve to multiple providers
    /// simultaneously. Writes never federate, regardless of subject.
    ///
    /// The default is `false` — flipping a subject to `true` is a non-breaking expansion
    /// (it just enables a multi-select picker variant for that subject's read flow). The
    /// reverse is breaking, so we default conservatively.
    var allowsReadFederation: Bool {
        switch self {
        case .fitness:
            return true
        case .calendar, .contacts, .tasks, .mail, .photos, .music, .location, .home, .screenTime:
            return false
        }
    }

    /// User-visible name for use in picker headers, settings rows, etc.
    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .tasks: return "Tasks"
        case .mail: return "Mail"
        case .photos: return "Photos"
        case .fitness: return "Fitness"
        case .music: return "Music"
        case .location: return "Location"
        case .home: return "Home"
        case .screenTime: return "Screen Time"
        }
    }
}
