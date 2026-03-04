# Convos Vault — Multi-Device Key Sync & Recovery

## Overview

Convos Vault is a hidden XMTP group conversation that acts as a secure, trustless channel for syncing private keys across a user's devices. It uses existing conversation primitives — messages, invites, locking, profiles, members — with dedicated content types and UI.

Convos uses a per-conversation identity model: each conversation has its own secp256k1 private key and XMTP inbox. A user with 20 conversations has 20 separate private keys stored in their device keychain. Convos Vault solves the problem of making those keys available on multiple devices without any server ever having access to the key material.

## Why not server-side sync?

Convos is trustless by design. The Convos backend never has access to user private keys. Key material only travels through XMTP's end-to-end encrypted MLS protocol — the same trust model used for regular messages.

## Why not XMTP multi-installation (addAccount)?

XMTP supports associating multiple wallet identities with a single inbox via `addAccount`. However, Convos creates a separate XMTP inbox per conversation (for privacy), meaning there are N private keys to manage, not one. The `addAccount` flow doesn't scale to this model — each new conversation would require a new cross-device association ceremony. Instead, we sync the actual private keys through an encrypted channel that the user controls.

## Architecture

The Vault is a standard XMTP group conversation with:

- A `conversationType` field in `ConversationCustomMetadata` (protobuf field 6) set to `"vault"` — this is how any device identifies the Vault after syncing its conversation list
- Custom XMTP content types for key exchange
- Locked by default (no new members can join without explicit user action)
- Members represent devices, with profile display names as device names

### Conversation type in custom metadata

The Vault must be identifiable by any device that syncs the conversation, without prior local state. When a new device joins and pulls its conversation list, it reads `ConversationCustomMetadata.conversationType` to distinguish the Vault from regular conversations.

```protobuf
message ConversationCustomMetadata {
    string tag = 1;
    repeated ConversationProfile profiles = 2;
    optional sfixed64 expiresAtUnix = 3;
    optional bytes imageEncryptionKey = 4;
    optional EncryptedImageRef encryptedGroupImage = 5;
    optional string conversationType = 6;  // "vault" for Convos Vault
}
```

The conversations list filters out any conversation where `conversationType == "vault"`. The Vault is only accessible through Settings → Convos Vault.

## Lifecycle

### 1. First device install

When a user installs Convos for the first time:

- A Vault conversation is created automatically
- The device is the sole member
- The device's profile display name is set to the device name (e.g., "Jarod's iPhone")
- The Vault is locked immediately

The Vault's private key is stored in iCloud Keychain by default on Apple devices, syncing automatically across the user's Apple devices.

On non-Apple platforms (Android, web), the Vault key must be presented to the user for manual backup during setup. This could be a mnemonic phrase or a copyable key string. The app should block progression until the user confirms they've saved it, since there is no platform-level key sync equivalent to iCloud Keychain.

### 2. Pairing a second device

The user opens Vault settings on the first device and taps "Pair Device":

1. The Vault is unlocked temporarily
2. A fresh invite tag is generated with a 30-second expiry (not stored in conversation metadata permanently)
3. A QR code is displayed containing the invite slug
4. A random 6-digit confirmation code is displayed on screen

The invite can only be redeemed once. After the device joins (or the invite expires), the invite tag is invalidated and the Vault is re-locked.

### 3. Second device joins

The new device installs Convos and selects "Pair with existing device":

1. Creates its own XMTP inbox (fresh key pair) — this is the device's Vault identity
2. Scans the QR code using the device camera
3. Joins the Vault conversation via the invite
4. Is prompted to enter the 6-digit code displayed on the first device
5. Sends the code as a message to the Vault for verification

### 4. First device confirms

The first device sees the join request with the confirmation code. It either auto-verifies or prompts the user to confirm the code matches. Once confirmed:

1. A `DeviceKeyBundle` message is sent containing all existing conversation private keys
2. The new device receives this, imports all keys, and calls `Client.create()` for each conversation inbox
3. The new device is now a second installation on every existing conversation

### 5. Ongoing sync

Whenever any linked device creates or joins a conversation:

1. The new conversation's private key is sent to the Vault as a `DeviceKeyShare` message
2. Other devices pick it up via normal XMTP message sync
3. Each device imports the key and adds itself as an installation for that conversation

## Custom Content Types

| Content Type | Purpose |
|---|---|
| `DeviceKeyBundle` | Full export of all conversation private keys (sent during initial pairing) |
| `DeviceKeyShare` | Single conversation key (sent when a new conversation is created or joined) |
| `DeviceKeyRequest` | Request keys from other devices (e.g., after reinstall with recovery key) |

All content types are XMTP custom content types, encrypted end-to-end by MLS. The key material is only readable by Vault members (the user's devices).

## Locking

The Vault stays locked by default:

- No new members can join
- The invite mechanism is disabled
- Key sync messages flow freely between existing members

When the user wants to add a device:

- They explicitly unlock the Vault
- A short-lived invite tag is generated
- After the new device joins (or the invite expires), the Vault auto-locks

This reuses the existing lock/unlock infrastructure.

## Managing Devices

Accessible from Settings → Convos Vault:

- List of linked devices (members with profile display names as device names)
- Last active timestamp per device
- "Pair Device" button (unlocks Vault, generates invite)
- Swipe to remove a device (removes from group, revokes XMTP installations for that inbox)
- Device names are editable (profile display name updates)

## Recovery

### Lost one device (other devices remain)

User removes the lost device from the Vault on another device. The removed device's inbox is kicked from the group, preventing it from receiving future keys. For conversation keys the lost device already had, those installations should be revoked via `revokeInstallations()`.

### Lost all devices (same Apple ID)

Since the Vault key is stored in iCloud Keychain, installing Convos on a new device signed into the same Apple ID will automatically recover the Vault key:

1. User installs Convos on a new device
2. The Vault key is retrieved from iCloud Keychain
3. The app rebuilds the XMTP client for the Vault inbox and syncs message history
4. Replays all `DeviceKeyBundle` and `DeviceKeyShare` messages to reconstruct the full set of conversation keys
5. Creates installations for each conversation

### Lost all devices (different Apple ID / no iCloud Keychain)

If the user backed up their Vault key (manual backup on non-Apple platforms, or exported from settings):

1. User installs Convos on a new device
2. Enters their Vault key manually
3. Same recovery flow as above — rebuild client, replay history, restore keys

If no backup exists, this is unrecoverable in a trustless model. No server holds the keys.

## Future Extensions

### Convos Credits (IAP)

The Vault can serve as a trustless purchase ledger:

- Credit purchases are recorded as messages in the Vault (including Apple's JWS-signed transaction data for verification)
- Credit spends are recorded as messages
- Current balance is derived by replaying purchase and spend history
- Deduplication by Apple transaction ID prevents double-counting
- Apple's signature on each transaction prevents fabricated purchases
- Balance survives reinstall (same recovery flow as key sync)
- Balance syncs across devices automatically

### Preferences Sync

Global preferences (like the reveal mode and include-info defaults) could be synced through the Vault rather than stored in local `UserDefaults`, giving cross-device consistency.

## Web App Support

A web app is just another device in the Vault. It creates an XMTP inbox, joins the Vault via QR pairing, receives keys, and stores them in Web Crypto API / IndexedDB. Its storage is less durable than iOS Keychain, so the web should be treated as a session device that can re-request keys from the Vault if storage is cleared.

## Device Offline for Extended Period

Keys accumulate as messages in the Vault. When the device comes back online, it syncs the conversation and imports all missed keys. XMTP message persistence handles this naturally.

## Open Questions

1. **Bidirectional verification**: Should pairing require both devices to confirm codes from each other's screens (like Bluetooth pairing), or is the one-way 6-digit code sufficient?
2. **Key rotation**: Should conversation keys in the Vault be rotatable? If a device is compromised and removed, can existing conversation keys be rotated?
3. **Maximum devices**: Should there be a limit on linked devices?
4. **Vault conversation expiry**: The Vault conversation should probably not have an expiry timer. Need to ensure the explode/expiry system exempts it.
