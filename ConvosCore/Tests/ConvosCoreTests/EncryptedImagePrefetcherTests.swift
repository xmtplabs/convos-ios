@testable import ConvosCore
import Foundation
import Testing

/// Loader stub that always throws a fixed error and counts invocations.
private actor ThrowingLoader: EncryptedImageLoaderProtocol {
    private(set) var callCount: Int = 0
    private let error: any Error

    init(throwing error: any Error) {
        self.error = error
    }

    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        callCount += 1
        throw error
    }
}

private func makeProfile() -> DBMemberProfile {
    DBMemberProfile(
        conversationId: "conversation-\(UUID().uuidString)",
        inboxId: "inbox-\(UUID().uuidString)",
        name: nil,
        avatar: "https://example.com/\(UUID().uuidString).bin",
        avatarSalt: Data(count: 32),
        avatarNonce: Data(count: 12),
        avatarKey: Data(count: 32)
    )
}

/// Coverage for the prefetcher's retry policy: transient errors get the
/// bounded retry, deterministic failures (decryption cannot heal - the
/// ciphertext and key material are immutable for a URL) get exactly one
/// attempt and no retry.
struct EncryptedImagePrefetcherTests {
    @Test("Permanent decryption failure is not retried")
    func permanentFailureGetsSingleAttempt() async {
        let loader = ThrowingLoader(throwing: ImageEncryptionError.decryptionFailed)
        let prefetcher = EncryptedImagePrefetcher(loader: loader)

        await prefetcher.prefetchProfileImages(profiles: [makeProfile()], groupKey: Data(count: 32))

        #expect(await loader.callCount == 1)
    }

    @Test("Known-bad URL short-circuits without retry")
    func knownBadURLGetsSingleAttempt() async {
        let loader = ThrowingLoader(throwing: EncryptedImageKnownBadURL())
        let prefetcher = EncryptedImagePrefetcher(loader: loader)

        await prefetcher.prefetchProfileImages(profiles: [makeProfile()], groupKey: Data(count: 32))

        #expect(await loader.callCount == 1)
    }

    @Test("Transient network failure keeps the bounded retry")
    func transientFailureIsRetried() async {
        let loader = ThrowingLoader(throwing: URLError(.timedOut))
        let prefetcher = EncryptedImagePrefetcher(loader: loader)

        await prefetcher.prefetchProfileImages(profiles: [makeProfile()], groupKey: Data(count: 32))

        #expect(await loader.callCount == 2)
    }
}
