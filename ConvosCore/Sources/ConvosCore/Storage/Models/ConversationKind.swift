import Foundation
import GRDB

// MARK: - ConversationKind

public enum ConversationKind: String, Codable, Hashable, SQLExpressible, CaseIterable, Sendable {
    case group, dm
}

public extension Array where Element == ConversationKind {
    static var all: [ConversationKind] {
        ConversationKind.allCases
    }

    static var groups: [ConversationKind] {
        [.group]
    }

    static var dms: [ConversationKind] {
        [.dm]
    }
}
