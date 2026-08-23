import Foundation

/// The timer set offered by the disappearing-messages surface. These familiar
/// Signal and WhatsApp choices map one-to-one to libxmtp's conversation-wide
/// retention duration.
public enum DisappearingMessageDuration: Int64, CaseIterable, Codable, Identifiable, Sendable {
    case oneMinute = 60_000_000_000
    case fiveMinutes = 300_000_000_000
    case oneHour = 3_600_000_000_000
    case eightHours = 28_800_000_000_000
    case twentyFourHours = 86_400_000_000_000
    case sevenDays = 604_800_000_000_000
    case ninetyDays = 7_776_000_000_000_000

    public var id: Int64 { rawValue }

    public var title: String {
        switch self {
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        case .ninetyDays: "90 days"
        }
    }

    /// Used when Pause proactively enables disappearing messages before this
    /// conversation has a previously selected timer.
    public static let privacyDefault: Self = .twentyFourHours

    public static func title(forRetentionDurationInNs duration: Int64) -> String {
        if let known = Self(rawValue: duration) {
            return known.title
        }

        let seconds = TimeInterval(duration) / 1_000_000_000
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours], width: .wide))
    }
}
