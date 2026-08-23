import Foundation

extension Date {
    /// Returns a short relative string like "1h", "12h", "1w", etc.
    public func relativeShort(to referenceDate: Date = .init()) -> String {
        let seconds = Int(referenceDate.timeIntervalSince(self))
        let minute = 60
        let hour   = 60 * minute
        let day    = 24 * hour
        let week   = 7 * day

        switch seconds {
        case 0..<30:
            return "now"
        case 30..<minute:
            return "\(seconds)s"
        case minute..<hour:
            return "\(seconds / minute)m"
        case hour..<day:
            return "\(seconds / hour)h"
        case day..<week:
            return "\(seconds / day)d"
        default:
            return "\(seconds / week)w"
        }
    }

    /// Long-form relative phrase for an "Updated ..." line: "just now",
    /// "5 minutes ago", "2 hours ago".
    ///
    /// Distinct from `relativeShort`, which is the compact form the
    /// transcript's own timestamps use. Anything under a minute - including a
    /// clock that is briefly ahead - reads as "just now" rather than counting
    /// seconds, because a page that was updated seconds ago and one updated
    /// half a minute ago are the same news.
    public func relativeLong(to referenceDate: Date = .init()) -> String {
        let seconds = referenceDate.timeIntervalSince(self)
        guard seconds >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: self, relativeTo: referenceDate)
    }

    public var nanosecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1_000_000_000.0)
    }
}
