@testable import ConvosCore
import Foundation
import Testing

@Suite("MockDatabaseManager Tests")
struct MockDatabaseManagerTests {
    @Test("replaceDatabase throws backupSourceMissing when path doesn't exist")
    func replaceDatabaseRefusesMissingSource() throws {
        let manager = MockDatabaseManager.makeTestDatabase()
        let bogusURL = URL(fileURLWithPath: "/tmp/convos-tests-does-not-exist-\(UUID().uuidString).sqlite")

        var caughtError: (any Error)?
        do {
            try manager.replaceDatabase(with: bogusURL)
        } catch {
            caughtError = error
        }

        #expect(caughtError is MockDatabaseManagerError)
        if case let .backupSourceMissing(path) = caughtError as? MockDatabaseManagerError {
            #expect(path == bogusURL.path)
        } else {
            Issue.record("expected .backupSourceMissing, got \(String(describing: caughtError))")
        }
    }
}
