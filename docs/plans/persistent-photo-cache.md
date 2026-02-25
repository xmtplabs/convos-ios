# Persistent Photo Cache

> **Status**: Draft
> **Author**: @jarod
> **Created**: 2026-02-24

## Problem

Chat photo attachments expire from S3 after 30 days and are never renewed (ADR 008). The local disk cache is the only surviving copy after expiration. However, the current `ImageCache` caps disk storage at 500MB with LRU eviction, meaning old photos are silently and permanently lost once evicted.

Additionally, when a conversation is exploded or deleted, the cached photos remain on disk as orphans — wasting storage indefinitely since nothing cleans them up.

## Goals

1. Chat photo attachments must not be evicted by size-based cache pressure
2. Exploded/deleted conversation photos must be cleaned up from disk
3. Re-fetchable images (avatars, group images) should still be subject to cache limits
4. Minimal changes to the existing `ImageCache` API surface

## Design

### Two-tier disk storage

Split disk-cached images into two pools based on whether they can be re-fetched:

| Pool | Location | Eviction | Contents |
|------|----------|----------|----------|
| **Persistent** | `Application Support/PhotoStore/` | Only on conversation delete/explode | Chat photo attachments |
| **Cache** | `Caches/ImageCache/` (existing) | LRU at 500MB cap | Avatars, group images, QR codes, other re-fetchable images |

`Application Support` is backed up by the system and not subject to iOS cache eviction under storage pressure. `Caches` can be purged by iOS at any time, which is fine for re-fetchable images.

### How it works

**Saving photos**: When a chat photo attachment is cached (via `OutgoingMessageWriter` or `RemoteAttachmentLoader`), it is written to the persistent pool instead of the evictable cache pool. The identifier is the attachment key (either the local URL string for outgoing, or the stored remote attachment JSON hash for incoming).

**Reading photos**: `ImageCache` checks memory first, then persistent pool, then cache pool, then network. No API change needed — callers still use `image(for:)` and `imageAsync(for:)` by identifier.

**Cleanup on explode/delete**: When `cleanupInboxData` removes conversations from the DB, it also collects the attachment keys for those conversations' messages and deletes the corresponding files from the persistent pool.

### API changes

Add a new parameter to distinguish storage tier:

```swift
// New enum
public enum ImageStorageTier: Sendable {
    case cache      // LRU-evictable (avatars, group images)
    case persistent // only deleted explicitly (chat photos)
}

// New method on ImageCacheProtocol
func cacheImage(_ image: ImageType, for identifier: String, storageTier: ImageStorageTier)
func cacheData(_ data: Data, for identifier: String, storageTier: ImageStorageTier)
func removeImages(for identifiers: [String], storageTier: ImageStorageTier)
```

Existing methods default to `.cache` tier for backward compatibility.

### Cleanup on conversation delete

Add a method to `ImageCache`:

```swift
func removeAttachments(forConversationId conversationId: String, attachmentKeys: [String])
```

This deletes the persistent files for the given keys. Called from `cleanupInboxData` in `InboxStateMachine` after querying the attachment keys from `DBMessage` before deleting the message rows.

The query to collect attachment keys before deletion:

```swift
let attachmentKeys = try DBMessage
    .filter(DBMessage.Columns.conversationId == conversationId)
    .filter(DBMessage.Columns.attachmentKey != nil)
    .fetchAll(db)
    .compactMap { $0.attachmentKey }
```

### What about "Delete All Data"?

The app's "Delete All Data" flow already calls `cleanupInboxData` for each inbox, which will now clean up persistent photos as part of that flow. As a safety net, `removeAllPersistentImages()` can wipe the entire `PhotoStore` directory.

## Scope

### In scope
- Persistent storage pool for chat attachments
- Cleanup hook in conversation delete/explode flow

### Out of scope
- Migration of existing cached attachments (photos have not shipped to the App Store yet, so internal builds do not need migration)
- Re-upload recovery for expired assets with local cache (future enhancement noted in ADR 008)
- Changing the 30-day S3 lifecycle policy
- Compression or deduplication of persistent photos

## Risks

- **Disk usage growth**: Persistent photos accumulate without a size cap. Mitigated by cleanup on delete/explode, and by the fact that S3 lifecycle means the app only retains what was cached during the 30-day window.

## Related

- [ADR 008: Asset Lifecycle and Renewal](../adr/008-asset-lifecycle-and-renewal.md)
- [ADR 009: Encrypted Conversation Images](../adr/009-encrypted-conversation-images.md)
- `ConvosCore/Sources/ConvosCore/Image Cache/ImageCache.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` (`cleanupInboxData`)
- `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
