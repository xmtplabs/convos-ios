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
    public let myGlobalProfileLoadStatePublisher: AnyPublisher<MyGlobalProfileLoadState, Never>
    private let subject: CurrentValueSubject<MyGlobalProfileLoadState, Never>

    public init(initial: MyProfile? = nil) {
        let subject = CurrentValueSubject<MyGlobalProfileLoadState, Never>(.loaded(initial))
        self.subject = subject
        self.myGlobalProfileLoadStatePublisher = subject.eraseToAnyPublisher()
        self.myGlobalProfilePublisher = subject
            .compactMap { (state: MyGlobalProfileLoadState) -> MyProfile?? in
                guard case .loaded(let profile) = state else { return nil }
                return .some(profile)
            }
            .eraseToAnyPublisher()
    }

    public func fetch() throws -> MyProfile? {
        guard case .loaded(let profile) = subject.value else { return nil }
        return profile
    }

    public func setForTesting(_ profile: MyProfile?) {
        subject.send(.loaded(profile))
    }

    public func setLoadStateForTesting(_ state: MyGlobalProfileLoadState) {
        subject.send(state)
    }
}
