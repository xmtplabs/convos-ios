import Foundation

public struct DateGroup: Hashable, Sendable {
    public let date: Date

    public var value: String {
        MessagesDateFormatter.shared.string(from: date)
    }

    private var truncatedTimestamp: Int {
        Int(date.timeIntervalSince1970) / 60
    }

    public init(date: Date) {
        self.date = date
    }

    public static func == (lhs: DateGroup, rhs: DateGroup) -> Bool {
        lhs.truncatedTimestamp == rhs.truncatedTimestamp
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(truncatedTimestamp)
    }
}
