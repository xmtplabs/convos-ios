# Convos Vault — ConvosCore Integration Design

## Overview

The Vault inbox reuses the existing inbox infrastructure (`InboxStateMachine`, `InboxLifecycleManager`, `MessagingService`, push notification handler) rather than maintaining a parallel system. This document describes how the Vault fits into each layer.

## Database: Identifying the Vault Inbox

Add an `isVault` boolean column to the `inbox` table:

```swift
migrator.registerMigration("addIsVaultToInbox") { db in
    try db.alter(table: "inbox") { t in
        t.add(column: "isVault", .boolean).notNull().defaults(to: false)
    }
}
```

Update `DBInbox` to include the flag. The Vault inbox is written to the database during first-time setup with `isVault: true`.

## Keychain: Vault Identity Storage

The Vault identity is stored in `KeychainIdentityStore` with a **separate service name** (`org.convos.ios.VaultIdentity.v1`) to keep it isolated from conversation identities. This prevents the Vault key from being accidentally deleted when conversation identities are cleaned up.

`VaultKeyStore` wraps a `KeychainIdentityStore` instance with this service name.

## Lifecycle: InboxLifecycleManager

The Vault inbox is managed by `InboxLifecycleManager` like any other inbox, with one key difference: **it is never put to sleep**. It should always be awake so key shares are received in real-time.

Changes to `InboxLifecycleManager`:
- `initializeOnAppLaunch`: Always wake the Vault inbox first, before other inboxes
- `sleepLeastRecentlyUsed`: Never select the Vault inbox for eviction
- The Vault inbox does not count against `maxAwakeInboxes`

The Vault inbox is identified by checking `DBInbox.isVault` when loading inboxes from the database.

## Auth: InboxStateMachine

The Vault uses the standard `InboxStateMachine` flow:
1. `handleRegister`: Generate keys, create XMTP client, save to keychain + database
2. `handleAuthorize`: Load keys, build XMTP client
3. `handleClientAuthorized`: Authenticate with backend (JWT), start syncing
4. Background/foreground handling works identically

The only difference: the Vault identity is stored in the Vault-specific keychain service, so `InboxStateMachine` needs to accept a `KeychainIdentityStoreProtocol` instance (it already does via dependency injection).

## Syncing: Vault Message Processor

The existing `SyncingManager` / `StreamProcessor` pipeline processes conversation messages (text, reactions, attachments, etc.). For the Vault inbox, we need a specialized processor that handles Vault content types.

Option A: A `VaultStreamProcessor` that conforms to the same interface as the existing `StreamProcessor`, but decodes `DeviceKeyBundle`, `DeviceKeyShare`, and `DeviceRemoved` content types instead of regular messages.

Option B: Add Vault content type handling to the existing `StreamProcessor` with a check: if the conversation has `conversationType == "vault"`, route to Vault-specific handling.

**Recommendation: Option A** — cleaner separation. The `MessagingService` would be configured with the Vault processor when creating the Vault's service instance.

## Push Notifications

### Registration
The Vault inbox is registered for push notifications through the standard flow. The backend receives the Vault's `clientId` during device registration and routes Vault group pushes to the device.

### Notification Extension Processing
When a push arrives for the Vault inbox:
1. `CachedPushNotificationHandler.handlePushNotification` looks up the `clientId`
2. Finds the Vault inbox in the database
3. Creates/gets a `MessagingService` for it
4. `processPushNotification` decrypts the message
5. **For Vault messages**: Import keys silently, return `nil` (suppress notification)
6. No user-visible notification is displayed

The notification extension identifies Vault messages by checking `DBInbox.isVault` for the matched inbox, or by checking the content type of the decoded message.

## Conversation Filtering

The Vault group conversation must not appear in the conversations list. Since it lives in its own XMTP client (separate inboxId), it naturally won't appear in conversation queries for other inboxes. However, the `DBInbox` with `isVault: true` should be excluded from inbox counts and inbox-related UI.

## SessionManager Integration

`SessionManager.initializeOnAppLaunch`:
1. Check if a Vault identity exists in `VaultKeyStore`
2. If yes: register the Vault inbox with `InboxLifecycleManager` and wake it
3. If no: skip (Vault will be created during pairing flow)

`SessionManager.deleteAllData`:
- Also delete the Vault identity from `VaultKeyStore`
- Delete the Vault inbox from the database

## Key Share Hook

After `InboxStateMachine.handleRegister` saves a new conversation identity:
1. Check if the Vault is connected and has multiple devices
2. If yes: send a `DeviceKeyShare` to the Vault group

This is implemented via `VaultKeyShareNotifier.conversationKeyCreated()`, which the `VaultManager` (wrapping the Vault's `MessagingService`) handles.

## First-Time Vault Setup

When the user creates their first conversation (or explicitly during onboarding):
1. Generate Vault keys via `VaultKeyStore`
2. Create the Vault inbox (register with XMTP, save to keychain + database with `isVault: true`)
3. Create the Vault group conversation (with `conversationType: "vault"` metadata)
4. Register with `InboxLifecycleManager`

This happens once per device. Subsequent app launches just wake the existing Vault inbox.

## Implementation Order

1. Database migration: add `isVault` to `DBInbox`
2. Update `InboxLifecycleManager`: never sleep Vault, wake first on launch
3. Create `VaultStreamProcessor` for Vault content type handling
4. Wire `SessionManager` to start Vault on launch
5. Wire `InboxStateMachine` key share hook
6. Wire notification extension to suppress Vault notifications
