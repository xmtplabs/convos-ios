import ConvosCore
import DifferenceKit
import Foundation
import UIKit

struct DateGroup: Hashable {
    var value: String

    init(date: Date) {
        self.value = MessagesDateFormatter.shared.string(from: date)
    }
}

extension ConversationUpdate: @retroactive Differentiable {
    public var differenceIdentifier: Int {
        summary.hashValue
    }

    public func isContentEqual(to source: ConversationUpdate) -> Bool {
        self.summary == source.summary
    }
}

extension DateGroup: Differentiable {
    var differenceIdentifier: Int {
        value.hashValue
    }

    func isContentEqual(to source: DateGroup) -> Bool {
        self.value == source.value
    }
}

extension Invite: @retroactive Differentiable {
    public var differenceIdentifier: Int {
        hashValue
    }

    public func isContentEqual(to source: Invite) -> Bool {
        self == source
    }
}

struct MessageGroup: Hashable {
    var id: String
    var title: String
    var source: MessageSource
}

extension MessageGroup: Differentiable {
    var differenceIdentifier: Int {
        hashValue
    }

    func isContentEqual(to source: MessageGroup) -> Bool {
        self == source
    }
}

enum ImageSource: Hashable {
    case image(UIImage)
    case imageURL(URL)
    var isLocal: Bool {
        switch self {
        case .image: return true
        case .imageURL: return false
        }
    }
}

extension AnyMessage: @retroactive Differentiable {
    public var differenceIdentifier: Int {
        base.id.hashValue
    }

    public func isContentEqual(to source: AnyMessage) -> Bool {
        self == source
    }
}
