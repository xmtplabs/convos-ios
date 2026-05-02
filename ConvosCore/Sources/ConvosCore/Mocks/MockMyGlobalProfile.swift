import Combine
import CryptoKit
import Foundation

public final class MockMyGlobalProfileWriter: MyGlobalProfileWriterProtocol, @unchecked Sendable {
    public private(set) var stored: MyProfile?

    public init(stored: MyProfile? = nil) {
        self.stored = stored
    }

    public func save(name: String?, imageData: Data?, imageAssetIdentifier: String?, metadata: ProfileMetadata?) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let inboxId = stored?.inboxId ?? "mock-inbox-id"
        stored = MyProfile(
            inboxId: inboxId,
            name: resolvedName,
            imageData: imageData,
            imageAssetIdentifier: imageData == nil ? nil : imageAssetIdentifier,
            imageContentDigest: Self.digest(of: imageData),
            metadata: (metadata?.isEmpty ?? true) ? nil : metadata,
            updatedAt: Date()
        )
    }

    public func update(name: String?) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let base = stored ?? MyProfile(inboxId: "mock-inbox-id")
        stored = MyProfile(
            inboxId: base.inboxId,
            name: resolved,
            imageData: base.imageData,
            imageAssetIdentifier: base.imageAssetIdentifier,
            imageContentDigest: base.imageContentDigest,
            metadata: base.metadata,
            updatedAt: Date()
        )
    }

    public func update(imageData: Data?, imageAssetIdentifier: String?) async throws {
        let base = stored ?? MyProfile(inboxId: "mock-inbox-id")
        stored = MyProfile(
            inboxId: base.inboxId,
            name: base.name,
            imageData: imageData,
            imageAssetIdentifier: imageData == nil ? nil : imageAssetIdentifier,
            imageContentDigest: Self.digest(of: imageData),
            metadata: base.metadata,
            updatedAt: Date()
        )
    }

    public func update(metadata: ProfileMetadata?) async throws {
        let base = stored ?? MyProfile(inboxId: "mock-inbox-id")
        stored = MyProfile(
            inboxId: base.inboxId,
            name: base.name,
            imageData: base.imageData,
            imageAssetIdentifier: base.imageAssetIdentifier,
            imageContentDigest: base.imageContentDigest,
            metadata: (metadata?.isEmpty ?? true) ? nil : metadata,
            updatedAt: Date()
        )
    }

    private static func digest(of imageData: Data?) -> String? {
        guard let imageData else { return nil }
        return Data(SHA256.hash(data: imageData)).base64EncodedString()
    }

    public func delete() async throws {
        stored = nil
    }
}

public final class MockMyGlobalProfileRepository: MyGlobalProfileRepositoryProtocol, @unchecked Sendable {
    public let myGlobalProfilePublisher: AnyPublisher<MyProfile?, Never>
    private let subject: CurrentValueSubject<MyProfile?, Never>

    public init(initial: MyProfile? = nil) {
        let subject = CurrentValueSubject<MyProfile?, Never>(initial)
        self.subject = subject
        self.myGlobalProfilePublisher = subject.eraseToAnyPublisher()
    }

    public func fetch() throws -> MyProfile? {
        subject.value
    }

    public func setForTesting(_ profile: MyProfile?) {
        subject.send(profile)
    }
}
