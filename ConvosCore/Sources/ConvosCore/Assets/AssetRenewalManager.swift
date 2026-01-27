import Foundation
import GRDB

public actor AssetRenewalManager {
    public static let defaultRenewalInterval: TimeInterval = 15 * 24 * 60 * 60 // 15 days
    private static let batchSize: Int = 100 // API limit

    private let databaseWriter: any DatabaseWriter
    private let apiClient: any ConvosAPIClientProtocol
    private let recoveryHandler: ExpiredAssetRecoveryHandler
    private let renewalInterval: TimeInterval
    private var isRenewalInProgress: Bool = false

    public init(
        databaseWriter: any DatabaseWriter,
        apiClient: any ConvosAPIClientProtocol,
        recoveryHandler: ExpiredAssetRecoveryHandler,
        renewalInterval: TimeInterval = AssetRenewalManager.defaultRenewalInterval
    ) {
        self.databaseWriter = databaseWriter
        self.apiClient = apiClient
        self.recoveryHandler = recoveryHandler
        self.renewalInterval = renewalInterval
    }

    public func performRenewalIfNeeded() async {
        guard !isRenewalInProgress else { return }
        isRenewalInProgress = true
        defer { isRenewalInProgress = false }
        _ = await performRenewal(forceAll: false)
    }

    public func forceRenewal() async -> AssetRenewalResult? {
        await performRenewal(forceAll: true)
    }

    public func renewSingleAsset(_ asset: RenewableAsset) async -> AssetRenewalResult? {
        guard let key = asset.key else { return nil }

        do {
            let result = try await apiClient.renewAssetsBatch(assetKeys: [key])

            if result.expiredKeys.contains(key) {
                await recoveryHandler.handleExpiredAsset(asset)
            }

            if result.renewed > 0 {
                do {
                    try await recordRenewalInDatabase(for: [asset])
                } catch {
                    // Note: We log but continue because the actual renewal succeeded on the server.
                    // Asset will be re-renewed on next check, which is safe (idempotent).
                    Log.error("Renewal succeeded but failed to record timestamp (asset will be re-checked): \(error.localizedDescription)")
                }
            }

            return result
        } catch {
            Log.error("Single asset renewal failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func performRenewal(forceAll: Bool) async -> AssetRenewalResult? {
        do {
            let assets: [RenewableAsset]
            if forceAll {
                assets = try collectAllAssets()
            } else {
                let staleThreshold = Date().addingTimeInterval(-renewalInterval)
                assets = try collectStaleAssets(olderThan: staleThreshold)
            }
            guard !assets.isEmpty else {
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            var keyToAsset: [String: RenewableAsset] = [:]
            let assetKeys = assets.compactMap { asset -> String? in
                guard let key = asset.key else { return nil }
                keyToAsset[key] = asset
                return key
            }
            guard !assetKeys.isEmpty else {
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            var totalRenewed = 0
            var totalFailed = 0
            var allExpiredKeys: [String] = []

            for batch in assetKeys.chunked(into: Self.batchSize) {
                do {
                    let result = try await apiClient.renewAssetsBatch(assetKeys: batch)
                    totalRenewed += result.renewed
                    totalFailed += result.failed
                    allExpiredKeys.append(contentsOf: result.expiredKeys)

                    let batchExpiredSet = Set(result.expiredKeys)
                    let renewedAssets = batch
                        .filter { !batchExpiredSet.contains($0) }
                        .compactMap { keyToAsset[$0] }

                    for expiredKey in result.expiredKeys {
                        if let asset = keyToAsset[expiredKey] {
                            await recoveryHandler.handleExpiredAsset(asset)
                        }
                    }

                    do {
                        try await recordRenewalInDatabase(for: renewedAssets)
                    } catch {
                        // Note: We log but continue because the actual renewal succeeded on the server.
                        // Assets will be re-renewed on next check, which is safe (idempotent).
                        Log.error("Renewal succeeded but failed to record timestamps (assets will be re-checked): \(error.localizedDescription)")
                    }
                } catch {
                    Log.error("Batch renewal failed, continuing with remaining batches: \(error.localizedDescription)")
                    totalFailed += batch.count
                }
            }

            Log.info("Asset renewal: \(totalRenewed) renewed, \(totalFailed) failed")

            return AssetRenewalResult(renewed: totalRenewed, failed: totalFailed, expiredKeys: allExpiredKeys)
        } catch {
            Log.error("Asset renewal failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func collectStaleAssets(olderThan threshold: Date) throws -> [RenewableAsset] {
        let collector = AssetRenewalURLCollector(databaseReader: databaseWriter)
        return try collector.collectStaleAssets(olderThan: threshold)
    }

    private func collectAllAssets() throws -> [RenewableAsset] {
        let collector = AssetRenewalURLCollector(databaseReader: databaseWriter)
        return try collector.collectRenewableAssets()
    }

    private func recordRenewalInDatabase(for assets: [RenewableAsset]) async throws {
        let now = Date()
        try await databaseWriter.write { db in
            for asset in assets {
                switch asset {
                case let .profileAvatar(url, _, _, _):
                    // Update ALL profiles with this avatar URL (same person may appear in multiple conversations)
                    let profiles = try DBMemberProfile
                        .filter(DBMemberProfile.Columns.avatar == url)
                        .fetchAll(db)
                    for var profile in profiles {
                        profile = profile.with(avatarLastRenewed: now)
                        try profile.save(db)
                    }
                case let .groupImage(url, _, _):
                    // Update ALL conversations with this image URL (for consistency with ExpiredAssetRecoveryHandler)
                    let conversations = try DBConversation
                        .filter(DBConversation.Columns.imageURLString == url)
                        .fetchAll(db)
                    for var conv in conversations {
                        conv = conv.with(imageLastRenewed: now)
                        try conv.save(db)
                    }
                }
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
