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

The main device (Device A) initiates pairing from Vault settings:

1. Device A taps "Pair Device" — this generates a standard Convos invite for the Vault (60-second expiry, single-use) and displays the QR code
2. Device B (new device) scans the QR code
3. Device B generates a random 6-digit confirmation code and displays it on screen
4. Device B sends a join request via DM (the standard invite join flow) — the join request includes Device B's inbox ID, the 6-digit code, and the device name (e.g., "Jarod's iPad")
5. Device A receives the join request and prompts: "Enter the code shown on your new device"
6. The owner reads the code off Device B's screen and types it into Device A
7. Device A matches the entered code against the code in the join request — this confirms the correct inbox ID to add
8. Device A adds Device B to the Vault conversation — Device B's profile display name in the Vault is set to the device name from the join request
9. The invite tag is invalidated and the Vault is re-locked

**Reuses the existing invite system:** The QR code is a standard Convos invite slug. The join request travels via DM, the same as any conversation invite. The only addition is the 6-digit confirmation code embedded in the join request, which Device A must verify before accepting.

**Why the code is in the join request:** Multiple join requests could arrive if others also scanned the QR. The 6-digit code ties the confirmation to a specific request, ensuring Device A adds the correct inbox ID.

**Security model:** The 6-digit code proves Device A's owner has physical access to Device B's screen. Even if someone else scans the QR, Device A's owner won't enter their code. Device B is never added to the Vault without Device A explicitly confirming the code match.

**Timing:** The entire pairing flow — scanning the QR, generating and displaying the code, entering the code on Device A, and verification — must complete within the 60-second invite expiry. If the invite expires before the code is confirmed, pairing fails and Device A must generate a new invite.

### 3. Key exchange after pairing

Once Device B is added to the Vault:

1. Device A sends a `DeviceKeyBundle` message containing all existing conversation private keys
2. If Device B had its own conversations, Device B also sends a `DeviceKeyBundle` with its keys (see Vault Merging below)
3. Both devices import each other's keys and call `Client.create()` for each new conversation inbox
4. Both devices are now installations on all conversations

### 4. Vault merging

When Device B already has its own Vault (from prior independent use), pairing requires merging:

**Prerequisite:** Device B must be the sole member of its own Vault before pairing. If Device B's Vault has other devices (C, D), those must be removed first. This prevents devices silently migrating into a new Vault without individual pairing ceremonies.

The app should check this and show an error: "Remove all other devices from your Vault before pairing with another device."

**Merge flow:**

1. Pairing completes — Device B is added to Device A's Vault
2. Device B sends its `DeviceKeyBundle` (its conversation keys) to Device A's Vault
3. Device A imports Device B's keys
4. Device B's old Vault is abandoned (deleted locally, the conversation remains on XMTP but is no longer tracked)
5. Device B updates its iCloud Keychain (or manual backup) to store Device A's Vault key, replacing its old Vault key
6. Device A's Vault is now the single Vault for both devices

After merging, if the owner wants to re-add devices C and D, they pair each one individually with Device A using the standard pairing flow.

### 5. Ongoing sync

Whenever any linked device creates or joins a conversation:

1. The new conversation's private key is sent to the Vault as a `DeviceKeyShare` message
2. Other devices pick it up via normal XMTP message sync
3. Each device imports the key and adds itself as an installation for that conversation

## Custom Content Types

### JoinRequest (phase 1 — prerequisite)

A new custom content type that replaces the current plain-text invite slug sent via DM. The current join request is just the invite slug as a text message. A structured `JoinRequest` content type is more flexible and supports both regular conversation joins and Vault pairing.

| Field | Type | Required | Description |
|---|---|---|---|
| `inviteSlug` | string | yes | The URL-safe encoded signed invite (same as current text message) |
| `profile` | object | no | The joiner's profile (name, image) for display in join request UI |
| `metadata` | map | no | Extensible key-value pairs for context-specific data |

For regular conversation joins, only `inviteSlug` is required (with optional `profile`). For Vault pairing, the metadata map carries Vault-specific fields:

| Metadata Key | Value | Description |
|---|---|---|
| `deviceName` | string | Device name (e.g., "Jarod's iPad") |
| `confirmationCode` | string | 6-digit code for pairing verification |

This is backward-compatible — existing join request processing checks for the invite slug and ignores unknown fields.

### Vault Content Types

| Content Type | Purpose |
|---|---|
| `DeviceKeyBundle` | Full export of all conversation private keys + installation IDs (sent during initial pairing) |
| `DeviceKeyShare` | Single conversation key + installation ID (sent when a new conversation is created or joined) |
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

User removes the lost device from the Vault on another device. The removed device's inbox is kicked from the group, preventing it from receiving future keys. In a future phase, the installation IDs tracked in the Vault will be used to selectively revoke the compromised device's installations across all conversations via `revokeInstallations()`.

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

## Resolved Design Decisions

**Key rotation after device compromise:** Not needed. Revoking the compromised device's XMTP installations (via `revokeInstallations()`) for each conversation is sufficient. The compromised device is removed from the MLS group for every conversation, and MLS forward secrecy ensures it cannot decrypt any future messages. The private keys alone are useless without an active installation.

**Installation ID tracking:** When a device shares a conversation key (via `DeviceKeyBundle` or `DeviceKeyShare`), it also includes the installation ID it created for that conversation. This builds a mapping of device → installation IDs per conversation, which is needed to selectively revoke a specific device's installations without affecting other devices. Selective revocation based on this mapping is a future phase — for now, removing a device from the Vault prevents it from receiving future keys.

## Open Questions

1. **Maximum devices**: Should there be a limit on linked devices?
2. **Vault conversation expiry**: The Vault conversation should probably not have an expiry timer. Need to ensure the explode/expiry system exempts it.

