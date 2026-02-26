import Foundation

public actor DeferredAssetRecoveryQueue {
    public struct Entry: Sendable {
        public let asset: RenewableAsset
        public let retryCount: Int

        public init(asset: RenewableAsset, retryCount: Int) {
            self.asset = asset
            self.retryCount = retryCount
        }
    }

    private var entriesByURL: [String: Entry] = [:]
    private var orderedURLs: [String] = []
    private var isProcessing: Bool = false

    public init() {}

    public func enqueue(_ asset: RenewableAsset, retryCount: Int = 0) {
        let entry = Entry(asset: asset, retryCount: retryCount)
        if entriesByURL[asset.url] == nil {
            orderedURLs.append(asset.url)
        }
        entriesByURL[asset.url] = entry
    }

    public func nextBatchForProcessing() -> [Entry]? {
        guard !isProcessing else { return nil }

        let entries = orderedURLs.compactMap { entriesByURL[$0] }
        guard !entries.isEmpty else { return nil }

        isProcessing = true
        orderedURLs.removeAll()
        entriesByURL.removeAll()
        return entries
    }

    public func finishProcessing(requeue: [Entry]) {
        for entry in requeue {
            enqueue(entry.asset, retryCount: entry.retryCount)
        }
        isProcessing = false
    }

    public var count: Int {
        orderedURLs.count
    }
}
