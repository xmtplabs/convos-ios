import Combine
import Foundation
import GRDB

public protocol AgentTemplateContactsRepositoryProtocol: Sendable {
    /// Reactive publisher of all agent-template contacts, ordered
    /// alphabetically by resolved display name (case-insensitive).
    var agentTemplateContactsPublisher: AnyPublisher<[AgentTemplateContact], Never> { get }

    /// Synchronous fetch of the alphabetical agent-template-contact list.
    func fetchAll() throws -> [AgentTemplateContact]

    /// Fetches a single agent-template contact by `templateId`.
    func fetchContact(templateId: String) throws -> AgentTemplateContact?

    /// Indexed point read; true when `templateId` has a stored row.
    func isContact(templateId: String) throws -> Bool
}

final class AgentTemplateContactsRepository: AgentTemplateContactsRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    let agentTemplateContactsPublisher: AnyPublisher<[AgentTemplateContact], Never>

    init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
        self.agentTemplateContactsPublisher = ValueObservation
            .tracking { db in
                try AgentTemplateContactsRepository.fetchAllContacts(db)
            }
            .publisher(in: databaseReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    func fetchAll() throws -> [AgentTemplateContact] {
        try databaseReader.read { db in
            try AgentTemplateContactsRepository.fetchAllContacts(db)
        }
    }

    func fetchContact(templateId: String) throws -> AgentTemplateContact? {
        try databaseReader.read { db in
            try DBAgentTemplateContact
                .fetchOne(db, key: templateId)
                .map(AgentTemplateContact.init(dbAgentTemplateContact:))
        }
    }

    func isContact(templateId: String) throws -> Bool {
        try databaseReader.read { db in
            try DBAgentTemplateContact
                .filter(DBAgentTemplateContact.Columns.templateId == templateId)
                .fetchCount(db) > 0
        }
    }

    private static func fetchAllContacts(_ db: Database) throws -> [AgentTemplateContact] {
        // Case-insensitive sort done in Swift to keep behavior identical
        // across SQLite collations, matching `ContactsRepository`.
        try DBAgentTemplateContact
            .fetchAll(db)
            .map(AgentTemplateContact.init(dbAgentTemplateContact:))
            .sorted { lhs, rhs in
                lhs.resolvedDisplayName
                    .localizedCaseInsensitiveCompare(rhs.resolvedDisplayName) == .orderedAscending
            }
    }
}
