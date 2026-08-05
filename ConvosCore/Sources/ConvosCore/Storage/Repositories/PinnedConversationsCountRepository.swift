import Combine
import Foundation
import GRDB

public protocol PinnedConversationsCountRepositoryProtocol {
    var pinnedCount: AnyPublisher<Int, Never> { get }
    func fetchCount() throws -> Int
}

class PinnedConversationsCountRepository: PinnedConversationsCountRepositoryProtocol {
    private let databaseReader: DatabaseReader

    lazy var pinnedCount: AnyPublisher<Int, Never> = {
        ValueObservation
            .tracking { db in
                try db.composePinnedConversationsCount()
            }
            // Unrelated localState writes (unread, mute) would otherwise
            // re-emit an identical count.
            .removeDuplicates()
            .publisher(in: databaseReader)
            .replaceError(with: 0)
            .eraseToAnyPublisher()
    }()

    init(databaseReader: DatabaseReader) {
        self.databaseReader = databaseReader
    }

    func fetchCount() throws -> Int {
        try databaseReader.read { db in
            try db.composePinnedConversationsCount()
        }
    }
}

fileprivate extension Database {
    func composePinnedConversationsCount() throws -> Int {
        try ConversationLocalState
            .filter(ConversationLocalState.Columns.isPinned == true)
            .fetchCount(self)
    }
}
