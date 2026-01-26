import Foundation
import GRDB

public struct AssetRenewalStorage: Sendable {
    public static let shared: AssetRenewalStorage = AssetRenewalStorage()

    private enum Constant {
        static let lastRenewalDateKey: String = "assetRenewalLastDate"
        static let perAssetRenewalDatesKey: String = "assetRenewalPerAssetDates"
    }

    public func lastRenewalDate(for assetKey: String) -> Date? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey),
              let interval = dict[assetKey] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    public func nextRenewalDate(for assetKey: String, interval: TimeInterval = AssetRenewalManager.defaultRenewalInterval) -> Date? {
        guard let lastDate = lastRenewalDate(for: assetKey) else { return nil }
        return lastDate.addingTimeInterval(interval)
    }

    func shouldPerformRenewal(interval: TimeInterval) -> Bool {
        guard let lastRenewal = UserDefaults.standard.object(forKey: Constant.lastRenewalDateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastRenewal) >= interval
    }

    func recordRenewal() {
        UserDefaults.standard.set(Date(), forKey: Constant.lastRenewalDateKey)
    }

    func recordPerAssetRenewal(key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey) ?? [:]
        dict[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: Constant.perAssetRenewalDatesKey)
    }

    func recordPerAssetRenewals(keys: [String]) {
        var dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey) ?? [:]
        let now = Date().timeIntervalSince1970
        for key in keys {
            dict[key] = now
        }
        UserDefaults.standard.set(dict, forKey: Constant.perAssetRenewalDatesKey)
    }

    func pruneStaleKeys(validKeys: Set<String>) {
        guard var dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey) else {
            return
        }
        let staleKeys = dict.keys.filter { !validKeys.contains($0) }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys {
            dict.removeValue(forKey: key)
        }
        UserDefaults.standard.set(dict, forKey: Constant.perAssetRenewalDatesKey)
        Log.info("Pruned \(staleKeys.count) stale asset renewal keys")
    }
}

public actor AssetRenewalManager {
    public static let defaultRenewalInterval: TimeInterval = 15 * 24 * 60 * 60 // 15 days
    private static let batchSize: Int = 100

    private let databaseReader: any DatabaseReader
    private let apiClient: any ConvosAPIClientProtocol
    private let recoveryHandler: ExpiredAssetRecoveryHandler
    private let renewalInterval: TimeInterval
    private let storage: AssetRenewalStorage = .shared
    private var isRenewalInProgress: Bool = false

    public init(
        databaseReader: any DatabaseReader,
        apiClient: any ConvosAPIClientProtocol,
        recoveryHandler: ExpiredAssetRecoveryHandler,
        renewalInterval: TimeInterval = AssetRenewalManager.defaultRenewalInterval
    ) {
        self.databaseReader = databaseReader
        self.apiClient = apiClient
        self.recoveryHandler = recoveryHandler
        self.renewalInterval = renewalInterval
    }

    public func performRenewalIfNeeded() async {
        guard !isRenewalInProgress else { return }
        guard storage.shouldPerformRenewal(interval: renewalInterval) else { return }
        isRenewalInProgress = true
        defer { isRenewalInProgress = false }
        _ = await performRenewal()
    }

    public func forceRenewal() async -> AssetRenewalResult? {
        await performRenewal()
    }

    public func renewSingleAsset(_ asset: RenewableAsset) async -> AssetRenewalResult? {
        guard let key = asset.key else { return nil }

        do {
            let result = try await apiClient.renewAssetsBatch(assetKeys: [key])

            if result.renewed > 0 {
                storage.recordPerAssetRenewal(key: key)
            }

            if result.expiredKeys.contains(key) {
                await recoveryHandler.handleExpiredAsset(asset)
            }

            return result
        } catch {
            Log.error("Single asset renewal failed: \(error.localizedDescription)")
            return nil
        }
    }

    public static func lastRenewalDate(for assetKey: String) -> Date? {
        AssetRenewalStorage.shared.lastRenewalDate(for: assetKey)
    }

    public static func nextRenewalDate(for assetKey: String, interval: TimeInterval = defaultRenewalInterval) -> Date? {
        AssetRenewalStorage.shared.nextRenewalDate(for: assetKey, interval: interval)
    }

    private func performRenewal() async -> AssetRenewalResult? {
        do {
            let assets = try collectAssets()
            guard !assets.isEmpty else {
                storage.recordRenewal()
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            var keyToAsset: [String: RenewableAsset] = [:]
            let assetKeys = assets.compactMap { asset -> String? in
                guard let key = asset.key else { return nil }
                keyToAsset[key] = asset
                return key
            }
            guard !assetKeys.isEmpty else {
                storage.recordRenewal()
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            // Batch requests to respect server limit
            // Record progress after each batch to preserve partial success if later batch fails
            var totalRenewed = 0
            var totalFailed = 0
            var allExpiredKeys: [String] = []

            for batch in assetKeys.chunked(into: Self.batchSize) {
                do {
                    let result = try await apiClient.renewAssetsBatch(assetKeys: batch)
                    totalRenewed += result.renewed
                    totalFailed += result.failed
                    allExpiredKeys.append(contentsOf: result.expiredKeys)

                    // Record renewed keys from this batch immediately
                    let batchExpiredSet = Set(result.expiredKeys)
                    let batchRenewedKeys = batch.filter { !batchExpiredSet.contains($0) }
                    storage.recordPerAssetRenewals(keys: batchRenewedKeys)

                    // Handle expired assets from this batch
                    for expiredKey in result.expiredKeys {
                        if let asset = keyToAsset[expiredKey] {
                            await recoveryHandler.handleExpiredAsset(asset)
                        }
                    }
                } catch {
                    Log.error("Batch renewal failed, continuing with remaining batches: \(error.localizedDescription)")
                    totalFailed += batch.count
                }
            }

            storage.recordRenewal()

            // Prune keys for assets that no longer exist
            storage.pruneStaleKeys(validKeys: Set(assetKeys))

            Log.info("Asset renewal: \(totalRenewed) renewed, \(totalFailed) failed")

            return AssetRenewalResult(renewed: totalRenewed, failed: totalFailed, expiredKeys: allExpiredKeys)
        } catch {
            Log.error("Asset renewal failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func collectAssets() throws -> [RenewableAsset] {
        let collector = AssetRenewalURLCollector(databaseReader: databaseReader)
        return try collector.collectRenewableAssets()
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
