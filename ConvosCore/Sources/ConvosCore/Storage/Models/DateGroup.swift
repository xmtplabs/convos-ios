import Foundation

public struct DateGroup: Hashable, Sendable {
    public var value: String

    public init(date: Date) {
        self.value = MessagesDateFormatter.shared.string(from: date)
    }

    public init(value: String) {
        self.value = value
    }
}
