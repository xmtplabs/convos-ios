import Foundation

/// Reading the dates and times a Space document writes.
///
/// These mirror `components/dates.ts` in the SDK, including the rule that
/// matters most: **no timezone math**. A date is a calendar fact and a time is
/// a wall-clock fact — a 9am meeting is written `2026-08-14T09:00` and every
/// reader sees 9 AM, wherever they are. Parsing through `DateFormatter` in the
/// device's zone would shift both, and a date near midnight would land on the
/// wrong day. So the components are read straight out of the string.
enum SpaceDay {
    private static let months: [String] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    /// `yyyy-MM-dd` read literally, or nothing when the value is not one.
    static func parts(of value: String) -> (year: Int, month: Int, day: Int)? {
        let date = String(value.prefix(10))
        let pieces = date.split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]), pieces[0].count == 4,
              let month = Int(pieces[1]), (1...12).contains(month),
              let day = Int(pieces[2]), (1...31).contains(day) else {
            return nil
        }
        return (year, month, day)
    }

    /// "Today", "Tomorrow", "Yesterday" — or nothing for a day far enough away
    /// to have no name of its own, where the calendar date is all there is to say.
    static func name(of value: String, now: Date = Date()) -> String? {
        guard let parts = parts(of: value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        guard let then = calendar.date(from: components) else { return nil }
        // The reader's own day, compared as a calendar fact rather than an
        // instant, so a late-evening reader is not already on tomorrow.
        let local = Calendar.current.dateComponents([.year, .month, .day], from: now)
        var todayParts = DateComponents()
        todayParts.year = local.year
        todayParts.month = local.month
        todayParts.day = local.day
        guard let today = calendar.date(from: todayParts) else { return nil }
        let days = Int((then.timeIntervalSince(today) / 86_400).rounded())
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return nil
        }
    }

    /// `Aug 29`, the calendar date as the SDK writes it.
    static func dateLabel(of value: String) -> String? {
        guard let parts = parts(of: value),
              let month = months[safe: parts.month - 1] else {
            return nil
        }
        return "\(month) \(parts.day)"
    }

    /// `10:00 AM` from the clock a timestamp carries, or nothing when it
    /// carries none. Read literally, so an offset changes nothing.
    static func timeLabel(of value: String) -> String? {
        guard value.count >= 16 else { return nil }
        let time = value.dropFirst(11).prefix(5)
        let pieces = time.split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]), (0...23).contains(hour),
              let minute = Int(pieces[1]), (0...59).contains(minute) else {
            return nil
        }
        let half = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(String(format: "%02d", minute)) \(half)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
