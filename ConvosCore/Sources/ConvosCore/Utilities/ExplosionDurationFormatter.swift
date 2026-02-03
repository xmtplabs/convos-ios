import Foundation

public enum ExplosionDurationFormatter {
    public static func format(until date: Date) -> String {
        format(interval: date.timeIntervalSinceNow)
    }

    public static func format(from startDate: Date, until endDate: Date) -> String {
        format(interval: endDate.timeIntervalSince(startDate))
    }

    public static func format(interval: TimeInterval) -> String {
        guard interval > 0 else { return "< 1m" }

        let totalMinutes = Int(ceil(interval / 60))

        if totalMinutes >= 24 * 60 {
            let days = totalMinutes / (24 * 60)
            let remainingHours = (totalMinutes % (24 * 60)) / 60
            if remainingHours == 0 {
                return "\(days)d"
            }
            return "\(days)d \(remainingHours)h"
        } else if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        } else if totalMinutes > 0 {
            return "\(totalMinutes)m"
        } else {
            return "< 1m"
        }
    }
}
