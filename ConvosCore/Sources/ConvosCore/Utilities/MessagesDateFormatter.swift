import Foundation

public final class MessagesDateFormatter: @unchecked Sendable {
    public static let shared: MessagesDateFormatter = MessagesDateFormatter()
    private let formatter: DateFormatter = DateFormatter()
    private let queue: DispatchQueue = DispatchQueue(label: "com.app.MessagesDateFormatter")

    private init() {}

    public func string(from date: Date) -> String {
        return queue.sync {
            configureDateFormatter(for: date)
            return formatter.string(from: date)
        }
    }

    func configureDateFormatter(for date: Date) {
        switch true {
        case Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date):
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        case Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear):
            formatter.doesRelativeDateFormatting = false
            formatter.dateFormat = "EEEE hh:mm"
        case Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year):
            formatter.doesRelativeDateFormatting = false
            formatter.dateFormat = "E, d MMM, hh:mm"
        default:
            formatter.doesRelativeDateFormatting = false
            formatter.dateFormat = "MMM d, yyyy, hh:mm"
        }
    }
}
