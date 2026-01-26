import Foundation
import GRDB

public actor AssetRenewalManager {
    public static let defaultRenewalInterval: TimeInterval = 15 * 24 * 60 * 60 // 15 days

    private let databaseReader: any DatabaseReader
    private let apiClient: any ConvosAPIClientProtocol
    private let recoveryHandler: ExpiredAssetRecoveryHandler
    private let renewalInterval: TimeInterval

    private enum Constant {
        static let lastRenewalDateKey: String = "assetRenewalLastDate"
        static let perAssetRenewalDatesKey: String = "assetRenewalPerAssetDates"
    }

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
        guard shouldPerformRenewal() else { return }
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
                recordPerAssetRenewal(key: key)
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
        guard let dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey),
              let interval = dict[assetKey] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    public static func nextRenewalDate(for assetKey: String, interval: TimeInterval = defaultRenewalInterval) -> Date? {
        guard let lastDate = lastRenewalDate(for: assetKey) else { return nil }
        return lastDate.addingTimeInterval(interval)
    }

    private func performRenewal() async -> AssetRenewalResult? {
        do {
            let assets = try collectAssets()
            guard !assets.isEmpty else {
                recordRenewal()
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            var keyToAsset: [String: RenewableAsset] = [:]
            let assetKeys = assets.compactMap { asset -> String? in
                guard let key = asset.key else { return nil }
                keyToAsset[key] = asset
                return key
            }
            guard !assetKeys.isEmpty else {
                recordRenewal()
                return AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
            }

            let result = try await apiClient.renewAssetsBatch(assetKeys: assetKeys)
            recordRenewal()

            // Record per-asset renewal for successfully renewed keys (all except expired ones)
            let renewedKeys = assetKeys.filter { !result.expiredKeys.contains($0) }
            recordPerAssetRenewals(keys: renewedKeys)

            // Prune keys for assets that no longer exist
            pruneStaleKeys(validKeys: Set(assetKeys))

            Log.info("Asset renewal: \(result.renewed) renewed, \(result.failed) failed")

            for expiredKey in result.expiredKeys {
                if let asset = keyToAsset[expiredKey] {
                    await recoveryHandler.handleExpiredAsset(asset)
                }
            }

            return result
        } catch {
            Log.error("Asset renewal failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func shouldPerformRenewal() -> Bool {
        guard let lastRenewal = UserDefaults.standard.object(forKey: Constant.lastRenewalDateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastRenewal) >= renewalInterval
    }

    private func recordRenewal() {
        UserDefaults.standard.set(Date(), forKey: Constant.lastRenewalDateKey)
    }

    private func recordPerAssetRenewal(key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey) ?? [:]
        dict[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: Constant.perAssetRenewalDatesKey)
    }

    private func recordPerAssetRenewals(keys: [String]) {
        var dict = UserDefaults.standard.dictionary(forKey: Constant.perAssetRenewalDatesKey) ?? [:]
        let now = Date().timeIntervalSince1970
        for key in keys {
            dict[key] = now
        }
        UserDefaults.standard.set(dict, forKey: Constant.perAssetRenewalDatesKey)
    }

    private func pruneStaleKeys(validKeys: Set<String>) {
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

    private func collectAssets() throws -> [RenewableAsset] {
        let collector = AssetRenewalURLCollector(databaseReader: databaseReader)
        return try collector.collectRenewableAssets()
    }
}
