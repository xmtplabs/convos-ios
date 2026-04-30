import Combine
import Foundation
import GRDB

public protocol ContactsRepositoryProtocol: Sendable {
    /// Reactive publisher of all contacts ordered alphabetically by display
    /// name (case-insensitive). Updates whenever the contact table changes.
    var contactsPublisher: AnyPublisher<[Contact], Never> { get }

    /// Synchronous fetch of the alphabetical contact list.
    func fetchAll() throws -> [Contact]

    /// Indexed point read; returns true if the inboxId is present in the
    /// contact table.
    func isContact(inboxId: String) throws -> Bool

    /// Fetches a single contact by inboxId.
    func fetchContact(inboxId: String) throws -> Contact?
}

final class ContactsRepository: ContactsRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    let contactsPublisher: AnyPublisher<[Contact], Never>

    init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
        self.contactsPublisher = ValueObservation
            .tracking { db in
                try ContactsRepository.fetchAllContacts(db)
            }
            .publisher(in: databaseReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Contact] {
        try databaseReader.read { db in
            try ContactsRepository.fetchAllContacts(db)
        }
    }

    func isContact(inboxId: String) throws -> Bool {
        try databaseReader.read { db in
            try DBContact
                .filter(DBContact.Columns.inboxId == inboxId)
                .fetchCount(db) > 0
        }
    }

    func fetchContact(inboxId: String) throws -> Contact? {
        try databaseReader.read { db in
            try DBContact.fetchOne(db, key: inboxId).map(Contact.init(dbContact:))
        }
    }

    private static func fetchAllContacts(_ db: Database) throws -> [Contact] {
        let rows = try DBContact.fetchAll(db)
        // Case-insensitive sort done in Swift to keep behavior identical
        // across SQLite collations (idx_contact_displayName supports first
        // paint; the in-memory sort handles nil names by deferring to the
        // shortened inboxId fallback).
        return rows
            .map(Contact.init(dbContact:))
            .sorted { lhs, rhs in
                lhs.resolvedDisplayName
                    .localizedCaseInsensitiveCompare(rhs.resolvedDisplayName) == .orderedAscending
            }
    }
}
