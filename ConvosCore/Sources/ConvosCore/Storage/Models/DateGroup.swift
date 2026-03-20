import Foundation

public struct DateGroup: Hashable, Sendable {
    public let date: Date

    public var value: String {
        MessagesDateFormatter.shared.string(from: date)
    }

    public init(date: Date) {
        self.date = date
    }

    public static func == (lhs: DateGroup, rhs: DateGroup) -> Bool {
        lhs.date == rhs.date
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}
