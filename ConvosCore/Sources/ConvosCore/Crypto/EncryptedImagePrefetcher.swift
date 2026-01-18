import Foundation

protocol EncryptedImagePrefetcherProtocol: Sendable {
    func prefetchProfileImages(
        profiles: [DBMemberProfile],
        groupKey: Data
    ) async
}

actor EncryptedImagePrefetcher: EncryptedImagePrefetcherProtocol {
    private static let maxConcurrentDownloads: Int = 4
    private static let maxRetryAttempts: Int = 2
    private static let retryDelaySeconds: UInt64 = 1

    init() {}

    func prefetchProfileImages(
        profiles: [DBMemberProfile],
        groupKey: Data
    ) async {
        let profilesToFetch = await filterUncachedProfiles(profiles)
        guard !profilesToFetch.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0

            for profile in profilesToFetch {
                if activeCount >= Self.maxConcurrentDownloads {
                    await group.next()
                    activeCount -= 1
                }

                group.addTask {
                    await self.prefetchWithRetry(profile: profile, groupKey: groupKey)
                }
                activeCount += 1
            }

            await group.waitForAll()
        }
    }

    private func filterUncachedProfiles(_ profiles: [DBMemberProfile]) async -> [DBMemberProfile] {
        var uncached: [DBMemberProfile] = []
        for profile in profiles {
            guard profile.hasValidEncryptedAvatar,
                  let urlString = profile.avatar else {
                continue
            }

            if await ImageCacheContainer.shared.imageAsync(for: urlString) == nil {
                uncached.append(profile)
            }
        }
        return uncached
    }

    private func prefetchWithRetry(profile: DBMemberProfile, groupKey: Data) async {
        guard profile.hasValidEncryptedAvatar,
              let urlString = profile.avatar,
              let url = URL(string: urlString),
              let salt = profile.avatarSalt,
              let nonce = profile.avatarNonce else {
            return
        }

        var lastError: Error?

        for attempt in 0..<Self.maxRetryAttempts {
            do {
                let params = EncryptedImageParams(
                    url: url,
                    salt: salt,
                    nonce: nonce,
                    groupKey: groupKey
                )

                let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(params: params)

                guard let image = ImageType(data: decryptedData) else {
                    throw NSError(
                        domain: "EncryptedImagePrefetcher",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create image from decrypted data"]
                    )
                }
                ImageCacheContainer.shared.setImage(image, for: urlString)
                ImageCacheContainer.shared.setImage(image, for: profile.inboxId)
                Log.info("Prefetched encrypted profile image for: \(profile.inboxId)")
                return
            } catch {
                lastError = error
                if attempt < Self.maxRetryAttempts - 1 {
                    try? await Task.sleep(nanoseconds: Self.retryDelaySeconds * 1_000_000_000)
                }
            }
        }

        if let error = lastError {
            Log.error("Failed to prefetch encrypted profile image after \(Self.maxRetryAttempts) attempts: \(error)")
        }
    }
}
