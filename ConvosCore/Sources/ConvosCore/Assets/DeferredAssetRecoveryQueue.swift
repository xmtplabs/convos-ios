import Foundation

public actor DeferredAssetRecoveryQueue {
    private var assetsByURL: [String: RenewableAsset] = [:]
    private var orderedURLs: [String] = []

    public init() {}

    public func enqueue(_ asset: RenewableAsset) {
        if assetsByURL[asset.url] == nil {
            orderedURLs.append(asset.url)
        }
        assetsByURL[asset.url] = asset
    }

    public func drain() -> [RenewableAsset] {
        let assets = orderedURLs.compactMap { assetsByURL[$0] }
        orderedURLs.removeAll()
        assetsByURL.removeAll()
        return assets
    }

    public var count: Int {
        orderedURLs.count
    }
}
