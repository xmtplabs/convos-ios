@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("MyGlobalProfile", .serialized)
struct MyGlobalProfileTests {
    @Test("save round-trips through the repository")
    func saveRoundTrip() async throws {
        let fixture = try await Fixture.make()
        let imageData = Data([0x01, 0x02, 0x03])
        try await fixture.writer.save(name: "Alice", imageData: imageData, imageAssetIdentifier: nil, metadata: nil)

        let profile = try fixture.repository.fetch()
        #expect(profile?.inboxId == fixture.inboxId)
        #expect(profile?.name == "Alice")
        #expect(profile?.imageData == imageData)
        #expect(profile?.metadata == nil)
    }

    @Test("save trims whitespace and clamps to maxDisplayNameLength")
    func saveTrims() async throws {
        let fixture = try await Fixture.make()
        let padded = "  Alice  "
        try await fixture.writer.save(name: padded, imageData: nil, imageAssetIdentifier: nil, metadata: nil)

        let profile = try fixture.repository.fetch()
        #expect(profile?.name == "Alice")
    }

    @Test("update(name:) preserves imageData and metadata")
    func updateNamePreservesOtherFields() async throws {
        let fixture = try await Fixture.make()
        let imageData = Data([0xAA, 0xBB])
        let metadata: ProfileMetadata = ["emoji": .string("🚀")]
        try await fixture.writer.save(name: "Alice", imageData: imageData, imageAssetIdentifier: nil, metadata: metadata)

        try await fixture.writer.update(name: "Bob")

        let profile = try fixture.repository.fetch()
        #expect(profile?.name == "Bob")
        #expect(profile?.imageData == imageData)
        #expect(profile?.metadata?["emoji"] == .string("🚀"))
    }

    @Test("update(imageData:) preserves name and metadata")
    func updateImagePreservesOtherFields() async throws {
        let fixture = try await Fixture.make()
        let metadata: ProfileMetadata = ["emoji": .string("🌟")]
        try await fixture.writer.save(name: "Alice", imageData: nil, imageAssetIdentifier: nil, metadata: metadata)

        let imageData = Data([0xCC, 0xDD])
        try await fixture.writer.update(imageData: imageData, imageAssetIdentifier: "asset-xyz")

        let profile = try fixture.repository.fetch()
        #expect(profile?.name == "Alice")
        #expect(profile?.imageData == imageData)
        #expect(profile?.metadata?["emoji"] == .string("🌟"))
    }

    @Test("update(metadata:) collapses empty metadata to nil")
    func updateEmptyMetadataIsNil() async throws {
        let fixture = try await Fixture.make()
        try await fixture.writer.save(name: "Alice", imageData: nil, imageAssetIdentifier: nil, metadata: ["emoji": .string("🌟")])

        try await fixture.writer.update(metadata: [:])

        let profile = try fixture.repository.fetch()
        #expect(profile?.metadata == nil)
    }

    @Test("delete removes the row")
    func deleteRemovesRow() async throws {
        let fixture = try await Fixture.make()
        try await fixture.writer.save(name: "Alice", imageData: Data([0x01]), imageAssetIdentifier: nil, metadata: nil)
        #expect(try fixture.repository.fetch() != nil)

        try await fixture.writer.delete()
        #expect(try fixture.repository.fetch() == nil)
    }

    @Test("save overwrites prior row")
    func saveOverwrites() async throws {
        let fixture = try await Fixture.make()
        try await fixture.writer.save(name: "Alice", imageData: Data([0x01]), imageAssetIdentifier: nil, metadata: nil)
        try await fixture.writer.save(name: "Bob", imageData: nil, imageAssetIdentifier: nil, metadata: nil)

        let profile = try fixture.repository.fetch()
        #expect(profile?.name == "Bob")
        #expect(profile?.imageData == nil)
    }

    @Test("repository fetch returns nil before any save")
    func fetchReturnsNilWhenEmpty() async throws {
        let fixture = try await Fixture.make()
        #expect(try fixture.repository.fetch() == nil)
    }

    @Test("imageAssetIdentifier round-trips and is cleared when imageData is nil")
    func imageAssetIdentifierRoundTrip() async throws {
        let fixture = try await Fixture.make()
        try await fixture.writer.save(
            name: "Alice",
            imageData: Data([0x01]),
            imageAssetIdentifier: "asset-abc",
            metadata: nil
        )
        #expect(try fixture.repository.fetch()?.imageAssetIdentifier == "asset-abc")

        try await fixture.writer.update(imageData: nil, imageAssetIdentifier: "asset-ignored")
        #expect(try fixture.repository.fetch()?.imageAssetIdentifier == nil)
    }
}

private struct Fixture {
    let inboxId: String
    let writer: any MyGlobalProfileWriterProtocol
    let repository: any MyGlobalProfileRepositoryProtocol
    let dbManager: MockDatabaseManager

    static func make() async throws -> Fixture {
        let inboxId = "fixture-inbox-\(UUID().uuidString)"
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let mockClient = MockXMTPClientProvider(inboxId: inboxId)
        let sessionStateManager = MockSessionStateManager(
            initialState: .ready(.init(client: mockClient, apiClient: MockAPIClient())),
            mockClient: mockClient
        )
        let writer = MyGlobalProfileWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: dbManager.dbWriter
        )
        let repository = MyGlobalProfileRepository(
            sessionStateManager: sessionStateManager,
            databaseReader: dbManager.dbReader
        )
        return Fixture(inboxId: inboxId, writer: writer, repository: repository, dbManager: dbManager)
    }
}
