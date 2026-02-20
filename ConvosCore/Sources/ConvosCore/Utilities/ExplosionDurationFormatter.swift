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

    // MARK: - Countdown (HH:MM:SS)

    public static func countdown(until date: Date, from now: Date = Date()) -> String {
        countdown(interval: date.timeIntervalSince(now))
    }

    public static func countdown(interval: TimeInterval) -> String {
        guard interval > 0 else { return "Exploding..." }

        let totalSeconds = Int(ceil(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            if remainingHours == 0 {
                return "\(days)d"
            }
            return "\(days)d \(remainingHours)h"
        } else {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }

    // MARK: - Compact Countdown (HH:MM for badge)

    public static func compactCountdown(interval: TimeInterval) -> String {
        guard interval > 0 else { return "Exploding..." }
        let totalSeconds = Int(ceil(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours >= 24 {
            let days = hours / 24
            return "\(days)d"
        } else if hours == 0 && minutes == 0 {
            return String(format: "00:%02d", seconds)
        } else {
            return String(format: "%02d:%02d", hours, minutes)
        }
    }
}
