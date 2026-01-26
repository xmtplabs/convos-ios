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

    private var inflightFetches: [String: Task<Void, Never>] = [:]
    private let loader: any EncryptedImageLoaderProtocol

    init(loader: any EncryptedImageLoaderProtocol = EncryptedImageLoaderInstance.shared) {
        self.loader = loader
    }

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
        var seen: Set<String> = []
        var uncached: [DBMemberProfile] = []
        for profile in profiles {
            guard profile.hasValidEncryptedAvatar else {
                continue
            }

            let hydratedProfile = profile.hydrateProfile()
            let identifier = hydratedProfile.imageCacheIdentifier

            guard !seen.contains(identifier) else {
                continue
            }
            seen.insert(identifier)

            let notCached = await ImageCacheContainer.shared.imageAsync(for: hydratedProfile) == nil
            let urlChanged = await ImageCacheContainer.shared.hasURLChanged(profile.avatar, for: identifier)

            if notCached || urlChanged {
                uncached.append(profile)
            }
        }
        return uncached
    }

    private func prefetchWithRetry(profile: DBMemberProfile, groupKey: Data) async {
        let inboxId = profile.inboxId

        if let existingTask = inflightFetches[inboxId] {
            await existingTask.value
            return
        }

        let task = Task<Void, Never> {
            await self.doFetch(profile: profile, groupKey: groupKey)
        }
        inflightFetches[inboxId] = task

        await task.value
        inflightFetches.removeValue(forKey: inboxId)
    }

    private func doFetch(profile: DBMemberProfile, groupKey: Data) async {
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

                let decryptedData = try await loader.loadAndDecrypt(params: params)

                let hydratedProfile = profile.hydrateProfile()
                // Use data-based overload to avoid re-compression quality loss
                ImageCacheContainer.shared.cacheAfterUpload(decryptedData, for: hydratedProfile.imageCacheIdentifier, url: urlString)
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
