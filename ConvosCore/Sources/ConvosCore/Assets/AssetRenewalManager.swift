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

        do {
            let assets = try collectAssets()
            guard !assets.isEmpty else {
                recordRenewal()
                return
            }

            var keyToAsset: [String: RenewableAsset] = [:]
            let assetKeys = assets.compactMap { asset -> String? in
                guard let key = asset.key else { return nil }
                keyToAsset[key] = asset
                return key
            }
            guard !assetKeys.isEmpty else {
                recordRenewal()
                return
            }

            let result = try await apiClient.renewAssetsBatch(assetKeys: assetKeys)
            recordRenewal()

            Log.info("Asset renewal: \(result.renewed) renewed, \(result.failed) failed")

            for expiredKey in result.expiredKeys {
                if let asset = keyToAsset[expiredKey] {
                    await recoveryHandler.handleExpiredAsset(asset)
                }
            }
        } catch {
            Log.error("Asset renewal failed: \(error.localizedDescription)")
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

    private func collectAssets() throws -> [RenewableAsset] {
        let collector = AssetRenewalURLCollector(databaseReader: databaseReader)
        return try collector.collectRenewableAssets()
    }
}
