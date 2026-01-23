# Asset Uploads

> **Status**: Approved
> **Author**: @lourou
> **Created**: 2026-01-16
> **Updated**: 2026-01-23

## Overview

Implement lifecycle management for S3-hosted image assets using a single bucket with automatic expiration. All assets expire after 30 days of inactivity. Profile and group images are renewed by the client every ~15 days, the expiry and resetting the 30-day clock. Chat images are never renewed and expire naturally.

## Research & Design Rationale

### S3 Lifecycle Insights

During research, several important S3 behaviors were discovered:

1. **S3 lifecycle rules cannot evaluate tag values dynamically**
   - Rules can check if a tag exists or matches an exact value
   - Rules cannot evaluate "is the timestamp in tag `t` older than 30 days"
   - Lifecycle expiration is always based on object age (`LastModified` date)

2. **Updating tags does NOT reset object age**
   - If you update an object's tags, the `LastModified` date stays the same
   - S3 lifecycle still counts from the original upload date
   - Tags are object metadata, not object content

3. **Copy-to-self resets `LastModified`**
    - The standard pattern to "touch" an S3 object and reset its age:
        
        ```tsx
        await s3.copyObject({
          CopySource: `${bucket}/${key}`,
          Bucket: bucket,
          Key: key
        });
        
        ```
        
    - This is a server-side operation (no data transfer)
    - Fast (milliseconds) and free (no egress costs)
    - Effectively resets the lifecycle clock
4. **S3 has no "objects without tag" filter**
    - You cannot write a lifecycle rule that targets only untagged objects
    - This eliminates the "tag profile images, leave chat images untagged" approach

### The Elegant Solution

Since copy-to-self resets the lifecycle clock, **we don't need prefixes, tags, or metadata at all**. The **renewal behavior** becomes the sole differentiator:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Single S3 Lifecycle Rule                     │
│                                                                 │
│    All objects expire 30 days after LastModified                │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Chat Images              Profile/Group Images                  │
│  ────────────             ────────────────────                  │
│  Upload → never           Upload → renewed every                │
│  renewed → expires        ~15 days → lives                      │
│  after 30 days            until not renewed                     │
│                                                                 │
│  ┌──────┐                 ┌──────┐                              │
│  │ Day 0│ Upload          │ Day 0│ Upload                       │
│  │Day 30│ Expired ✓       │Day 15│ Renew → LastModified reset   │
│  └──────┘                 │Day 30│ Renew → LastModified reset   │
│                           │ ...  │                              │
│                           └──────┘                              │
└─────────────────────────────────────────────────────────────────┘

```

### Why This Works

- **All objects look identical** in S3 (no prefix, no tags, no metadata)
- **URLs reveal nothing** about asset type. Privacy is preserved, absolutely no metadata leakage
- **One lifecycle rule** covers everything
- **Renewal is just copy-to-self** — simple, fast, free
- **Chat images expire naturally** after 30 days of no renewal
- **Profile/group images live indefinitely** as long as the app renews them

---

## Goals

- Single S3 bucket with one lifecycle rule (30-day expiration)
- No prefixes, tags, or metadata to differentiate asset types
- Client renews profile/group images every ~15 days (resets to +30 days from now)
- Chat images expire naturally after 30 days (never renewed)
- URLs are indistinguishable between asset types
- Renewal is fire-and-forget (non-blocking, best-effort)

## Non-Goals

- Prefix-based or tag-based routing
- Multiple S3 buckets
- Different base retention periods for different asset types
- Migrating existing assets
- Manual user controls for retention

---

## Technical Design

### Architecture

```
Upload Flow (All Assets):
┌──────────────────────────────────────────────────────────┐
│ User uploads image (chat, profile, or group)             │
│     ↓                                                    │
│ Backend: generate presigned URL                          │
│     ↓                                                    │
│ Client: upload to S3                                     │
│     ↓                                                    │
│ S3 object created: LastModified = now                    │
│     ↓                                                    │
│ S3 lifecycle: will expire in 30 days unless renewed      │
└──────────────────────────────────────────────────────────┘

Renewal Flow (On App Launch):
┌──────────────────────────────────────────────────────────┐
│ User opens app                                           │
│     ↓                                                    │
│ Check: has it been 15+ days since last renewal?          │
│     ↓                                                    │
│ If yes:                                                  │
│   - Collect my profile image URLs (from local DB)        │
│     Last renewal date is per attachment, store locally   │
│   - Collect group image URLs (groups I'm a member of)    │
│     Last renewal date store in group metadata            │
│   - POST /v2/assets/renew-batch { urls: [...] }          │
│     ↓                                                    │
│ Backend: s3.copyObject() for each (parallel)             │
│     ↓                                                    │
│ S3 objects: LastModified = now (clock reset)             │
│     ↓                                                    │
│ Record renewal timestamp locally                         │
│     ↓                                                    │
│ Fire-and-forget (don't block app launch)                 │
└──────────────────────────────────────────────────────────┘

Expired Asset Recovery (Inactive User Returns):
┌──────────────────────────────────────────────────────────┐
│ Bob hasn't opened app for 30+ days                       │
│     ↓                                                    │
│ Bob's profile image expired in S3                        │
│     ↓                                                    │
│ Bob opens app, app tries to renew                        │
│     ↓                                                    │
│ Backend returns 404 for Bob's profile image              │
│     ↓                                                    │
│ iOS detects 404 in batch response                        │
│     ↓                                                    │
│ iOS still has cached image locally!                      │
│     ↓                                                    │
│ iOS automatically re-uploads from cache                  │
│     ↓                                                    │
│ New URL for asset, fresh 30-day clock, Bob never noticed │
└──────────────────────────────────────────────────────────┘

The 404 from the renew endpoint is the signal that S3 lost the object.
The local cache is the source of truth for recovery. Seamless.
```

### S3 Object Structure

```
bucket/
  ├── abc123.bin     (could be chat image - no way to tell)
  ├── def456.bin     (could be profile image - no way to tell)
  └── ghi789.bin     (could be group image - no way to tell)

No prefixes. No tags. No metadata. All identical.

```

### Renewal Timing

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Lifecycle expiration | 30 days | Balance between storage cost and user experience |
| Renewal interval | 15 days | Comfortable buffer (50% of lifecycle) |
| Renewal trigger | App launch | Once per session, batched, non-blocking |

**What gets renewed:**

| Asset | Renewed by | Rationale |
|-------|------------|-----------|
| My profile image | Me | Owner keeps their own assets alive |
| Group images | Any group member | Groups stay alive if anyone is active |
| Other members' profile images | NOT renewed by me | Their responsibility — no tracking |

**Timeline example (active user):**

```
Day 0:  Upload profile image (LastModified = Day 0)
Day 15: User opens app → batch renew (LastModified = Day 15)
Day 30: User opens app → batch renew (LastModified = Day 30)
Day 45: User opens app → batch renew (LastModified = Day 45)
...continues indefinitely as long as user uses the app

```

**Expiration example (inactive user):**

```
Day 0:  Upload profile image (LastModified = Day 0)
Day 15: User opens app → batch renew (LastModified = Day 15)
        User stops using app entirely
Day 45: 30 days since last renewal → image expires in S3
Day 50: User returns, opens app
        → Renewal returns 404 for some assets
        → iOS has cached image locally
        → Auto-re-upload from cache
        → New URL, user never noticed anything

```

### Design Philosophy: Inactivity = Expiration

**This is intentional, not a bug.**

If a user doesn't open the app for 30+ days, their profile image expires. This is the correct behavior:

1. **The image isn't "lost"** — the user chose to be inactive
2. **Storage is finite** — inactive users shouldn't consume resources indefinitely
3. **Re-upload is trivial** — when the user returns, they simply set a new profile photo
4. **No tracking required** — we don't need to track who views whose images
5. **Simple mental model** — "use it or lose it"

**What about other users seeing expired images?**

If Alice is in a group with Bob, and Bob is inactive for 30+ days:

- Bob's profile image expires in S3
- Alice keeps seeing her locally cached version of Bob's image — no disruption
- When Bob returns and opens the app:
    - Renewal returns 404
    - Bob's app auto-re-uploads from local cache
    - New URL propagates to Alice via XMTP metadata sync
    - Alice's app fetches the new URL

**Alice only sees a placeholder if** she clears her cache or re-installs the app while Bob is inactive. Edge case.

The user experience is seamless for everyone.

### Collective responsibility in renewing the expiry date of assets

A user could potentially postpone the expiration of all the other users’ profile pictures. That would be a positive aspect to avoid profile pictures of inactive users from expiring.

However, this would require sharing the `lastRenewal` date for each profile picture in the conversation metadata, so that pictures are not renewed by all users at the same time. We’ve decided to let each user be responsible for renewing their own profile picture, as well as the group profile pictures for the groups they belong to.

---

## Testing Strategy

### Test Bucket Validation

**Before deploying to production, validate the approach with a test bucket:**

1. Create a test bucket with 1-day lifecycle (accelerated testing)
2. Upload test objects
3. Verify objects expire after 1 day
4. Call copy-to-self on some objects
5. Verify copied objects get new `LastModified`
6. Verify copied objects survive past original expiration
7. Confirm non-copied objects expire as expected

This validates the core assumption that copy-to-self resets the lifecycle clock.

### Manual Testing Scenarios

1. Upload profile image → verify `LastModified` set
2. Wait 20 days → call renewal → verify `LastModified` updated to today
3. Upload chat image → never renew → verify expires after 30 days
4. Load profile image in app → verify renewal endpoint called (after 15 days)

---

## Implementation Plan

### Phase 1: Test Bucket Validation

- Create test bucket with short lifecycle (1-2 days)
- Validate copy-to-self resets `LastModified`
- Validate lifecycle rule deletes unrenewed objects
- Document findings

### Phase 2: Infrastructure (Terraform)

- Add 30-day lifecycle rule to existing bucket
- No prefix filters, no tag filters
- Deploy to staging first

### Phase 3: Backend

- Add renewal endpoint (`PUT /v2/assets/renew`)
- Implement copy-to-self logic
- Add rate limiting / validation

### Phase 4: iOS Client

- Add `AssetRenewalManager` to track last renewal per URL
- Integrate renewal into image loading flow
- Fire-and-forget renewal calls (non-blocking)

### Phase 5: Rollout

- Deploy to production
- Monitor renewal endpoint traffic
- Monitor S3 object counts over time

---

## iOS Implementation

### New: `AssetRenewalManager`

```swift
actor AssetRenewalManager {
    static let shared = AssetRenewalManager()

    private let renewalIntervalKey = "lastAssetRenewalDate"
    private let renewalInterval: TimeInterval = 15 * 24 * 60 * 60  // 15 days

    func shouldPerformRenewal() -> Bool {
        guard let lastRenewal = UserDefaults.standard.object(forKey: renewalIntervalKey) as? Date else {
            return true  // Never renewed
        }
        return Date().timeIntervalSince(lastRenewal) >= renewalInterval
    }

    func recordRenewal() {
        UserDefaults.standard.set(Date(), forKey: renewalIntervalKey)
    }
}

```

### Integration Point: App Launch

```swift
// In SessionManager or AppDelegate, after user is authenticated
func onAppBecomeActive() {
    Task {
        await performAssetRenewalIfNeeded()
    }
}

private func performAssetRenewalIfNeeded() async {
    guard await AssetRenewalManager.shared.shouldPerformRenewal() else {
        return  // Renewed recently, skip
    }

    // Collect asset URLs from local database
    var assetUrls: [String] = []

    // My profile images (across all conversations I'm in)
    let myProfileUrls = await collectMyProfileImageUrls()
    assetUrls.append(contentsOf: myProfileUrls)

    // Group images for groups I'm a member of
    let groupImageUrls = await collectGroupImageUrls()
    assetUrls.append(contentsOf: groupImageUrls)

    guard !assetUrls.isEmpty else { return }

    // Extract S3 keys from full URLs (strip scheme + host, drop leading slash)
    // e.g. "https://cdn.example.com/abc123.bin" → "abc123.bin"
    let assetKeys = assetUrls.compactMap { url -> String? in
        guard let path = URL(string: url)?.path, path.count > 1 else { return nil }
        return String(path.dropFirst())
    }
    guard !assetKeys.isEmpty else { return }

    // Fire-and-forget batch renewal
    Task.detached {
        do {
            let result = try await apiClient.renewAssetsBatch(assetKeys: assetKeys)
            await AssetRenewalManager.shared.recordRenewal()

            // Handle expired assets (404s) — map keys back to full URLs for cache lookup
            for expiredKey in result.expiredKeys {
                let matchingUrl = assetUrls.first { url in
                    guard let path = URL(string: url)?.path, path.count > 1 else { return false }
                    return String(path.dropFirst()) == expiredKey
                }
                if let url = matchingUrl {
                    await handleExpiredAsset(url: url)
                }
            }
        } catch {
            Log.warning("Asset batch renewal failed (non-fatal): \(error)")
        }
    }
}

private func handleExpiredAsset(url: String) async {
    // Check if we have the image cached locally
    if let cachedImage = await imageCache.image(for: url) {
        // Auto-recover: re-upload from local cache
        do {
            let newUrl = try await reuploadImage(cachedImage, forExpiredUrl: url)
            Log.info("Auto-recovered expired asset: \(url) → \(newUrl)")
        } catch {
            Log.warning("Failed to auto-recover expired asset: \(error)")
            // Fall back to clearing the URL — user will see placeholder
            await databaseWriter.clearAssetUrl(url)
        }
    } else {
        // No local cache — clear URL, user will need to re-upload manually
        await databaseWriter.clearAssetUrl(url)
    }
}

```

### API Client Addition

```swift
extension ConvosAPIClient {
    struct BatchRenewResult {
        let renewed: Int
        let failed: Int
        let expiredKeys: [String]  // Keys that returned 404
    }

    func renewAssetsBatch(assetKeys: [String]) async throws -> BatchRenewResult {
        var request = try authenticatedRequest(for: "v2/assets/renew-batch", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct BatchRenewRequest: Encodable { let assetKeys: [String] }
        request.httpBody = try JSONEncoder().encode(BatchRenewRequest(assetKeys: assetKeys))

        struct BatchRenewResponse: Decodable {
            let renewed: Int
            let failed: Int
            let results: [AssetResult]

            struct AssetResult: Decodable {
                let key: String
                let success: Bool
                let error: String?
            }
        }

        let response: BatchRenewResponse = try await performRequest(request)

        let expiredKeys = response.results
            .filter { !$0.success && $0.error == "not_found" }
            .map { $0.key }

        return BatchRenewResult(
            renewed: response.renewed,
            failed: response.failed,
            expiredKeys: expiredKeys
        )
    }
}

```

### Files to Modify (iOS)

| File | Change |
| --- | --- |
| **NEW** `ConvosCore/.../AssetRenewalManager.swift` | Renewal timing actor |
| `ConvosCore/.../ConvosAPIClient.swift` | Add `renewAssetsBatch(assetKeys:)` method |
| `ConvosCore/.../ConvosAPIClientProtocol.swift` | Add `renewAssetsBatch(assetKeys:)` to protocol |
| `ConvosCore/.../SessionManager.swift` or similar | Trigger renewal on app launch |
| `ConvosCore/.../DatabaseWriter.swift` | Add `clearAssetUrl()` for expired assets |

---

## Appendix A: Terraform Requirements

> For use in the infrastructure repository
> 

### Overview

Add a single S3 lifecycle rule to the existing assets bucket. All objects expire 30 days after their `LastModified` date. No prefix filters, no tag filters.

### Lifecycle Configuration

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "assets_lifecycle" {
  bucket = aws_s3_bucket.convos_assets.id  # Reference existing bucket

  rule {
    id     = "expire-after-30-days"
    status = "Enabled"

    # No filter = applies to ALL objects in bucket
    filter {}

    expiration {
      days = 30
    }

    # Clean up incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

```

### Key Points

- **No prefix filter**: Rule applies to all objects
- **No tag filter**: Rule applies regardless of tags
- **30-day expiration**: Based on `LastModified` date
- **Renewal resets clock**: Client calls copy-to-self via backend endpoint

### Validation Steps

1. Apply to staging/test bucket first
2. Upload test object, note `LastModified`
3. Wait or use short lifecycle (1 day) for testing
4. Verify object deleted after lifecycle period
5. Test copy-to-self resets `LastModified`
6. Apply to production

### Test Bucket (Optional)

For validating the approach before production:

```hcl
resource "aws_s3_bucket" "lifecycle_test" {
  bucket = "convos-lifecycle-test-${var.environment}"
}

resource "aws_s3_bucket_lifecycle_configuration" "lifecycle_test" {
  bucket = aws_s3_bucket.lifecycle_test.id

  rule {
    id     = "expire-after-1-day"  # Accelerated for testing
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

```

---

## Appendix B: Backend Requirements

> For use in the backend repository
> 

### Overview

Add a batch endpoint that performs copy-to-self on multiple S3 objects to reset their `LastModified` dates, effectively extending their lifecycle by 30 days each.

### Endpoint Specification

```
POST /v2/assets/renew-batch
Content-Type: application/json
Authorization: Bearer <jwt>

Request:
{
  "assetKeys": [
    "abc123.bin",
    "def456.bin",
    "ghi789.bin"
  ]
}

Response (200 OK):
{
  "renewed": 2,
  "failed": 1,
  "results": [
    { "key": "abc123.bin", "success": true },
    { "key": "def456.bin", "success": true },
    { "key": "ghi789.bin", "success": false, "error": "not_found" }
  ]
}

Response (400 Bad Request):
{
  "error": "Invalid request body"
}

```

**Note:** iOS extracts keys from stored URLs via `URL(string: avatar)?.path.dropFirst()`

### Implementation

```tsx
// routes/assets.ts
import { S3Client, CopyObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({ region: process.env.AWS_REGION });
const BUCKET = process.env.S3_BUCKET;
const MAX_BATCH_SIZE = 100;

interface RenewResult {
  key: string;
  success: boolean;
  error?: string;
}

function isValidKey(key: string): boolean {
  // Keys should be non-empty and not contain path traversal
  return key.length > 0 && !key.includes("..") && !key.startsWith("/");
}

router.post("/v2/assets/renew-batch", authenticate, async (req, res) => {
  const { assetKeys } = req.body;

  if (!Array.isArray(assetKeys) || assetKeys.length === 0) {
    return res.status(400).json({ error: "assetKeys must be a non-empty array" });
  }

  if (assetKeys.length > MAX_BATCH_SIZE) {
    return res.status(400).json({ error: `Maximum ${MAX_BATCH_SIZE} keys per request` });
  }

  // Process all keys in parallel
  const results: RenewResult[] = await Promise.all(
    assetKeys.map(async (key): Promise<RenewResult> => {
      if (!isValidKey(key)) {
        return { key, success: false, error: "invalid_key" };
      }

      try {
        // Copy object to itself (resets LastModified)
        // CopyObject will fail if not found — no need to HeadObject first
        await s3.send(new CopyObjectCommand({
          Bucket: BUCKET,
          CopySource: `${BUCKET}/${key}`,
          Key: key,
          MetadataDirective: "COPY"
        }));

        return { key, success: true };
      } catch (error: any) {
        if (error.name === "NoSuchKey" || error.name === "NotFound") {
          return { key, success: false, error: "not_found" };
        }
        // Log unexpected errors but don't fail the whole batch
        console.error(`Failed to renew ${key}:`, error);
        return { key, success: false, error: "internal_error" };
      }
    })
  );

  const renewed = results.filter(r => r.success).length;
  const failed = results.filter(r => !r.success).length;

  return res.json({ renewed, failed, results });
});

```

### Security Considerations

1. **Authentication required**: Only authenticated users can renew assets
2. **No per-asset authorization**: Any authenticated user can renew any asset
    - Intentional: users renew their own assets + group assets they're members of
    - Worst case: unnecessary renewal (no harm, just extra S3 ops)
3. **Batch size limit**: Max 100 keys per request to prevent abuse
4. **Key validation**: Reject empty keys, path traversal (`..`), and leading slashes
5. **Rate limiting**: 10 batch requests per hour per device

### Rate Limiting

```tsx
const renewalLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,  // 1 hour
  max: 10,  // 10 batch requests per hour (up to 1000 assets)
  keyGenerator: (req, res) => res.locals.deviceId || req.ip,
  message: { error: "Too many renewal requests" }
});

router.post("/v2/assets/renew-batch", authenticate, renewalLimiter, async (req, res) => {
  // ...
});

```

### Testing

1. **Unit test**: Mock S3 client, verify `CopyObjectCommand` called for each key
2. **Unit test**: Verify 404s are returned as `not_found` errors (not thrown)
3. **Unit test**: Verify key validation rejects `..` and `/` prefixes
4. **Integration test**: Use localstack or test bucket
5. **Manual test**: Upload objects, call batch renew, verify `LastModified` changed

---

## Decisions

1. **What triggers a renewal?**
    - App launch (once per 15 days). Single batch request with all relevant keys.
    - NOT on image view — that would be tracking-like behavior.
2. **Why keys instead of full URLs?**
    - Decoupled from CDN domain — if domain changes, no backend update needed.
    - Smaller payload size.
    - Simpler backend — no URL parsing needed.
    - iOS extracts keys from stored URLs: `URL(string: avatar)?.path.dropFirst()`
3. **Should we persist renewal state across app sessions?**
    - Yes, using `UserDefaults` to store last renewal date.
    - This prevents unnecessary renewal calls on every app launch.
4. **Should renewal be authenticated per-asset?**
    - No. Any authenticated user can renew any asset.
    - Users renew their own profile images + group images they're members of.
    - Worst case: unnecessary renewal (no harm).
5. **What happens when an asset is expired (404)?**
    - Backend returns `not_found` in the batch response.
    - iOS checks local cache — if image exists, auto-re-upload!
    - New URL stored, user never notices.
    - If no local cache (edge case), clear URL → placeholder → manual re-upload.
6. **What about other users' profile images?**
    - NOT renewed by you — only the owner renews their own.
    - If Bob is inactive for 30+ days, his image expires.
    - Alice sees a placeholder for Bob — acceptable tradeoff.
    - When Bob returns and re-uploads, Alice sees the new image.

---

## References

- [S3 Lifecycle Configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [S3 CopyObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html)
- Existing PRD: `docs/plans/encrypted-images.md`
- Existing PRD: `docs/plans/public-preview-image-toggle.md`
