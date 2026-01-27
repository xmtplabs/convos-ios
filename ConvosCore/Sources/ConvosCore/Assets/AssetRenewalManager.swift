import Foundation
import GRDB

public actor AssetRenewalManager {
    public static let defaultRenewalInterval: TimeInterval = 15 * 24 * 60 * 60 // 15 days
    private static let batchSize: Int = 100

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
                    Log.error("Failed to record renewal timestamp: \(error.localizedDescription)")
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
                        Log.error("Failed to record renewal timestamps: \(error.localizedDescription)")
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
                case let .profileAvatar(url, conversationId, inboxId, _):
                    if var profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId),
                       profile.avatar == url {
                        profile = profile.with(avatarLastRenewed: now)
                        try profile.save(db)
                    }
                case let .groupImage(url, conversationId, _):
                    if var conversation = try DBConversation.fetchOne(db, key: conversationId),
                       conversation.imageURLString == url {
                        conversation = conversation.with(imageLastRenewed: now)
                        try conversation.save(db)
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
