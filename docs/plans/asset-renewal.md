# Asset Renewal Implementation Plan

## Summary

Implement client-side asset renewal for profile and group images to prevent S3 lifecycle expiration. The feature:
1. Renews S3-hosted images every ~15 days on app launch to prevent 30-day expiration
2. Clears expired image URLs (404s) from the database so users see placeholders

## Files Created

| File | Purpose |
|------|---------|
| `ConvosCore/Sources/ConvosCore/Assets/AssetRenewalManager.swift` | Actor managing renewal timing and orchestration |
| `ConvosCore/Sources/ConvosCore/Assets/AssetRenewalURLCollector.swift` | Database queries to collect asset metadata |
| `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift` | Clears expired asset URLs from database |

## Files Modified

| File | Change |
|------|--------|
| `ConvosCore/.../API/ConvosAPIClientProtocol.swift` | Add `renewAssetsBatch(assetKeys:)` method |
| `ConvosCore/.../API/ConvosAPIClient.swift` | Implement the method |
| `ConvosCore/.../API/ConvosAPIClient+Models.swift` | Add request/response models |
| `ConvosCore/.../API/MockAPIClient.swift` | Add mock implementation |
| `ConvosCore/.../Sessions/SessionManager.swift` | Integrate renewal in `initializationTask` |

---

## Implementation Details

### API Models (`ConvosAPIClient+Models.swift`)

```swift
// MARK: - v2/assets/renew-batch
public struct AssetRenewalResult: Sendable {
    public let renewed: Int
    public let failed: Int
    public let expiredKeys: [String]
}

extension ConvosAPI {
    struct BatchRenewRequest: Codable {
        let assetKeys: [String]
    }

    struct BatchRenewResponse: Codable {
        let renewed: Int
        let failed: Int
        let results: [AssetResult]

        struct AssetResult: Codable {
            let key: String
            let success: Bool
            let error: String?
        }
    }
}
```

### URL Collector (`AssetRenewalURLCollector.swift`)

Collects profile and group image metadata:

```swift
public enum RenewableAsset: Sendable {
    case profileAvatar(url: String, conversationId: String, inboxId: String)
    case groupImage(url: String, conversationId: String)

    public var url: String { ... }
    public var key: String? { ... }  // Extracts S3 key from URL path
}

struct AssetRenewalURLCollector {
    func collectRenewableAssets() throws -> [RenewableAsset]
}
```

### Renewal Manager (`AssetRenewalManager.swift`)

Actor that orchestrates renewal:

```swift
public actor AssetRenewalManager {
    public static let defaultRenewalInterval: TimeInterval = 15 * 24 * 60 * 60 // 15 days

    public func performRenewalIfNeeded() async {
        // 1. Check if 15+ days since last renewal
        // 2. Collect all asset URLs from database
        // 3. Extract S3 keys and call batch renewal API
        // 4. For expired assets (404), clear URL from database
        // 5. Record renewal timestamp
    }
}
```

### Expired Asset Handler (`ExpiredAssetRecoveryHandler.swift`)

Clears expired URLs from database:

```swift
public struct ExpiredAssetRecoveryHandler: Sendable {
    public func handleExpiredAsset(_ asset: RenewableAsset) async {
        // Clear the URL from database so user sees placeholder
    }
}
```

### SessionManager Integration

Added fire-and-forget Task in `initializationTask`:

```swift
Task(priority: .utility) { [weak self] in
    guard let self, !Task.isCancelled else { return }
    let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: self.databaseWriter)
    let renewalManager = AssetRenewalManager(
        databaseReader: self.databaseReader,
        apiClient: ConvosAPIClientFactory.client(environment: self.environment),
        recoveryHandler: recoveryHandler
    )
    await renewalManager.performRenewalIfNeeded()
}
```

---

## Behavior

1. On app launch, after inbox initialization, a background Task runs
2. Checks UserDefaults for last renewal timestamp
3. If 15+ days since last renewal (or never renewed):
   - Queries database for all profile avatar and group image URLs
   - Extracts S3 keys from URL paths
   - Calls `POST /v2/assets/renew-batch` with keys
   - For any expired assets (404), clears URL from database
4. Records renewal timestamp to UserDefaults

## Key Design Decisions

1. **Fire-and-forget**: Renewal runs in background, doesn't block app launch
2. **UserDefaults**: Simple persistence for last renewal date
3. **Actor isolation**: Thread-safe without manual locking
4. **Key extraction**: URLs stripped to S3 keys (`/abc123.bin` → `abc123.bin`)
5. **Simplified recovery**: Expired assets have their URLs cleared (user sees placeholder) rather than attempting re-upload, which would require waking sleeping inboxes

## Verification

1. **Build**: `/build` to verify compilation
2. **Manual Test - Renewal**:
   - Clear UserDefaults key `assetRenewalLastDate`
   - Launch app with profile/group images in database
   - Verify API call is made (check logs)
   - Verify subsequent launches skip renewal (within 15 days)
3. **Manual Test - Expired Assets**:
   - If an asset returns 404 during renewal
   - Verify URL is cleared from database
   - Verify user sees placeholder image
