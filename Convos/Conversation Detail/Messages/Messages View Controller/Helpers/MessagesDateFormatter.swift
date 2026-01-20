import Foundation

final class MessagesDateFormatter: @unchecked Sendable {
    static let shared: MessagesDateFormatter = MessagesDateFormatter()
    private let formatter: DateFormatter = DateFormatter()
    private let queue: DispatchQueue = DispatchQueue(label: "com.app.MessagesDateFormatter")

    private init() {}

    func string(from date: Date) -> String {
        return queue.sync {
            configureDateFormatter(for: date)
            return formatter.string(from: date)
        }
    }

    func attributedString(from date: Date, with attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        return queue.sync {
            let dateString = string(from: date)
            return NSAttributedString(string: dateString, attributes: attributes)
        }
    }

    func configureDateFormatter(for date: Date) {
        switch true {
        case Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date):
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        case Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear):
            formatter.dateFormat = "EEEE hh:mm"
        case Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year):
            formatter.dateFormat = "E, d MMM, hh:mm"
        default:
            formatter.dateFormat = "MMM d, yyyy, hh:mm"
        }
    }
}
