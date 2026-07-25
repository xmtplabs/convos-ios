#if canImport(UIKit)
import Foundation

public enum ExplodeDuration: CaseIterable {
    case sixtySeconds
    case oneHour
    case twentyFourHours
    case sundayAtMidnight

    public var label: String {
        switch self {
        case .sixtySeconds: return "60 seconds"
        case .oneHour: return "1 hour"
        case .twentyFourHours: return "24 hours"
        case .sundayAtMidnight: return "Sunday at midnight"
        }
    }

    public var shortLabel: String {
        switch self {
        case .sixtySeconds: return "60s"
        case .oneHour: return "1h"
        case .twentyFourHours: return "24h"
        case .sundayAtMidnight: return "Sun"
        }
    }

    public var timeInterval: TimeInterval {
        switch self {
        case .sixtySeconds: return 60
        case .oneHour: return 3600
        case .twentyFourHours: return 86400
        case .sundayAtMidnight:
            let calendar = Calendar.current
            let now = Date()
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = 1
            components.hour = 0
            components.minute = 0
            components.second = 0
            if let nextSunday = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 1), matchingPolicy: .nextTime) {
                return nextSunday.timeIntervalSince(now)
            }
            return 604800
        }
    }
}
#endif
