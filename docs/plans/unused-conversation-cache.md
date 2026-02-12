# Unused Conversation Cache

## Overview

Extend the existing `UnusedInboxCache` (renamed to `UnusedConversationCache`) to pre-create not just an XMTP inbox, but a complete ready-to-use conversation including the invite and QR codes. This eliminates all perceived latency when users create a new conversation.

## Problem

Currently, when a user creates a new conversation:
1. XMTP inbox is consumed from cache (fast) ✓
2. XMTP conversation is created and published (network call, slow)
3. Invite slug is generated and saved (crypto + DB, moderate)
4. QR code is generated when invite sheet opens (CPU-bound, moderate)

Steps 2-4 cause visible loading states and delays.

## Solution

Pre-create the entire conversation flow in the background:
- XMTP inbox (existing)
- XMTP conversation (new)
- Invite with signed slug (new)
- QR code images for light/dark modes (new)

When the user taps "New Conversation," everything is instantly available.

## Design

### Pre-creation Flow

```
1. Create XMTP inbox (existing logic)
2. Wait for inbox ready
3. Create XMTP conversation via client.prepareConversation() + publish()
4. Save conversation to DB with isUnused = true
5. Generate invite via InviteWriter.generate()
6. Pre-generate QR codes for light/dark modes via QRCodeGenerator.pregenerate()
7. Store conversation ID in keychain (alongside inbox ID)
```

All steps happen in background after app launch or after consuming the previous unused conversation.

### Consumption Flow

When user taps "New Conversation":

```
1. Check what's available in keychain/DB:

   a. If unusedConversationId exists in keychain:
      - Flip isUnused = false in database
      - Clear both keychain entries
      - Return MessagingService + conversation ID (fully ready)
      - Invite/QR already exist or generate on-demand

   b. Else if unusedInboxId exists in keychain (conversation failed):
      - Use pre-created inbox
      - Create conversation on demand
      - Generate invite on demand
      - Clear inbox from keychain
      - Return MessagingService + new conversation ID

   c. Else (nothing pre-created):
      - Fall back to current behavior (create everything on demand)

2. Schedule background creation of next unused conversation
```

The `ConversationStateManager` receives a conversation that's already in `.ready` state when fully pre-created, or creates the conversation using the pre-created inbox.

### Database Changes

**Migration:** Add `isUnused` column to `DBConversation`

```swift
migrator.registerMigration("addIsUnusedToConversation") { db in
    try db.alter(table: "conversation") { t in
        t.add(column: "isUnused", .boolean).notNull().defaults(to: false)
    }
}
```

**Filtering:** Update conversation list queries to exclude unused conversations:

```swift
.filter(DBConversation.Columns.isUnused == false)
```

### Keychain Storage

Currently stores: `unusedInboxId`

Add: `unusedConversationId`

Both are cleared together on consumption. If either is missing during preparation, recreate both.

### Error Handling

**Graceful degradation on partial failure:**

The inbox is the expensive part (XMTP client, network, keys). Conversation and invite generation are fast. If later steps fail, keep earlier work and fall back gracefully on consumption.

| Failure Point | What to Keep | On Consumption |
|--------------|--------------|----------------|
| Inbox fails | Nothing | Create everything on demand (current behavior) |
| Conversation fails | Inbox | Use pre-created inbox, create conversation on demand |
| Invite fails | Inbox + Conversation | Use pre-created inbox + conversation, generate invite on demand |
| QR fails | Inbox + Conversation + Invite | Use everything, QR generates on-demand anyway (non-fatal) |

**Keychain state reflects progress:**
- `unusedInboxId` set → inbox ready
- `unusedConversationId` set → conversation ready (implies inbox ready)
- Invite exists in DB for unused conversation → invite ready

On consumption, check what's available and pick up from there. The user always gets the maximum benefit from whatever succeeded.

**Stale unused conversation:**
- On app launch, validate the unused conversation still exists in DB
- If DB was cleared but keychain has IDs → clear keychain, create fresh

**Consumption race condition:**
- Already handled by actor isolation (existing pattern)
- Clear keychain immediately before any await points

### API Surface Changes

**Rename:** `UnusedInboxCache` → `UnusedConversationCache`

**Protocol changes:**

```swift
public protocol UnusedConversationCacheProtocol: Actor {
    /// Prepares an unused conversation (inbox + conversation + invite + QR)
    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async

    /// Consumes the unused conversation, returns ready-to-use service + conversation ID
    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?)

    /// Checks if given conversation ID is the unused one
    func isUnusedConversation(_ conversationId: String) -> Bool

    /// Clears unused inbox and conversation from keychain
    func clearUnusedFromKeychain()

    /// Checks if there is an unused conversation available
    func hasUnusedConversation() -> Bool
}
```

**Return type change:** `consumeOrCreateMessagingService` now returns a tuple with optional conversation ID (non-nil when unused conversation was consumed, nil when created fresh).

### Dependencies

`UnusedConversationCache` will need additional dependencies:

- `InviteWriter` - to generate invite slug
- `StreamProcessor` - to process conversation into database
- `QRCodeGenerator` (via platform providers) - to pre-generate QR codes

### Invite Metadata

Pre-generated invites are created with default/empty metadata. When the user customizes the conversation (name, description, image), the existing `InviteWriter.update()` flow regenerates the invite slug. The QR code is regenerated on-demand through the existing caching system.

## Files to Modify

1. `ConvosCore/Sources/ConvosCore/Messaging/UnusedInboxCache.swift` - Rename and extend
2. `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift` - Add `isUnused` column
3. `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` - Add migration
4. `ConvosCore/Sources/ConvosCore/Storage/Repositories/ConversationsRepository.swift` - Filter unused
5. `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainAccount.swift` - Add `unusedConversationId` account
6. Callers of `UnusedInboxCache` - Update to new name and handle conversation ID return

## Testing

- Unit test: Pre-creation completes with all artifacts (conversation in DB, invite in DB, QR in cache)
- Unit test: Consumption flips `isUnused` flag and clears keychain
- Unit test: Partial failure cleanup works correctly
- Unit test: Unused conversations filtered from list queries
- Integration test: Full flow from pre-creation through consumption
