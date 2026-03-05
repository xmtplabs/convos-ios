# Convos Vault — Technical Implementation Plan

This document details the technical implementation for the Convos Vault feature, building on the [design plan](convos-vault.md).

## Phase 1: Foundation

### 1.1 Protobuf: Add `conversationType` field

**File:** `ConvosAppData/Sources/ConvosAppData/Proto/conversation_custom_metadata.proto`

Add `optional string conversationType = 6` to `ConversationCustomMetadata`. Regenerate the `.pb.swift` file. The Vault conversation sets this to `"vault"`.

This allows any device to identify the Vault after syncing conversations, without relying on local state.

### 1.2 Vault content types

**Package:** `ConvosInvites` (or a new `ConvosVault` package — see decision below)

Three new custom XMTP content types:

#### `DeviceKeyBundle` (full key export)
Sent when a new device joins the Vault. Contains all conversation keys the sending device has.

```
ContentType: convos.org/device_key_bundle v1
```

Payload (JSON):
```json
{
  "keys": [
    {
      "conversationId": "<xmtp-conversation-id>",
      "inboxId": "<xmtp-inbox-id>",
      "clientId": "<convos-client-id>",
      "privateKeyData": "<base64>",
      "databaseKey": "<base64>"
    }
  ],
  "senderInstallationId": "<xmtp-installation-id>",
  "timestamp": "<iso8601>"
}
```

#### `DeviceKeyShare` (incremental sync)
Sent whenever a new conversation is created on any device. Contains a single key.

```
ContentType: convos.org/device_key_share v1
```

Payload (JSON):
```json
{
  "conversationId": "<xmtp-conversation-id>",
  "inboxId": "<xmtp-inbox-id>",
  "clientId": "<convos-client-id>",
  "privateKeyData": "<base64>",
  "databaseKey": "<base64>",
  "senderInstallationId": "<xmtp-installation-id>",
  "timestamp": "<iso8601>"
}
```

#### `DeviceRemoved`
Sent when a device is removed from the Vault. Other devices should stop sharing keys with it.

```
ContentType: convos.org/device_removed v1
```

Payload (JSON):
```json
{
  "removedInboxId": "<vault-member-inbox-id>",
  "reason": "user_removed | lost_device",
  "timestamp": "<iso8601>"
}
```

### 1.3 Package decision: `ConvosVault` vs extending `ConvosInvites`

**Recommendation: New `ConvosVault` package.**

Rationale:
- Vault is a distinct domain from invites (device sync vs group membership)
- Vault depends on `KeychainIdentityStore` types which live in `ConvosCore`
- Vault content types don't need the invite crypto layer
- Clean dependency graph: `ConvosVault` depends on `ConvosAppData` and `XMTPiOS`, but not `ConvosInvites`

However, the Vault *pairing flow* reuses the invite system (create invite, scan QR, send join request). The pairing coordinator in `ConvosVault` would import `ConvosInvites` for `sendJoinRequest` with metadata `["confirmationCode": "482916", "deviceName": "iPad"]`.

Alternative: Put content types in `ConvosCore` since they need `KeychainIdentityKeys`. The Vault manager itself lives in `ConvosCore` too, since it interacts with `KeychainIdentityStore`, `InboxStateMachine`, and the database.

**Decision needed from Jarod.**

## Phase 2: Vault Lifecycle

### 2.1 Vault creation (first install)

When the app starts for the first time:

1. Generate a Vault key pair (`KeychainIdentityKeys.generate()`)
2. Store the Vault key in the Keychain with a dedicated service name (e.g., `org.convos.ios.VaultIdentity.v1`)
3. Optionally store the Vault key in iCloud Keychain (for recovery on same Apple ID)
4. Create an XMTP client for the Vault inbox (`Client.create(account: vaultSigningKey, options: vaultClientOptions)`)
5. Create a group conversation with `conversationType: "vault"` in the custom metadata
6. Set the Vault group as locked (no expiry timer)
7. Set the device's profile display name to the device name (e.g., "Jarod's iPhone")

**Where this lives:** `VaultManager` actor in `ConvosCore`

```swift
public actor VaultManager {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let environment: AppEnvironment
    
    private var vaultClient: (any XMTPClientProvider)?
    private var vaultConversationId: String?
    
    func createVault() async throws { ... }
    func connectToVault() async throws { ... }
    func shareKey(_ identity: KeychainIdentity) async throws { ... }
    func importKeys(from bundle: DeviceKeyBundleContent) async throws { ... }
}
```

### 2.2 Vault key storage

The Vault key is stored separately from conversation keys:

| Storage | Key | Purpose |
|---------|-----|---------|
| Device Keychain | `org.convos.ios.VaultIdentity.v1` | Primary Vault key storage |
| iCloud Keychain | `org.convos.ios.VaultIdentity.iCloud.v1` | Recovery on same Apple ID |

The Vault key uses `kSecAttrAccessibleAfterFirstUnlock` (not `ThisDeviceOnly`) for the iCloud variant, allowing iCloud Keychain to sync it.

### 2.3 Vault XMTP client lifecycle

The Vault client runs alongside conversation clients but is separate:

- It uses `deviceSyncEnabled: true` (unlike conversation clients which use `false`)
- It only needs basic codecs: `TextCodec`, `DeviceKeyBundleCodec`, `DeviceKeyShareCodec`, `DeviceRemovedCodec`, `JoinRequestCodec`, `InviteJoinErrorCodec`
- It runs on its own database with its own encryption key
- It streams messages to detect incoming key shares from other devices

**Integration point:** The `SessionManager` starts the Vault client alongside the main session. The Vault client is a long-running background task.

### 2.4 Key sharing on conversation creation

When any conversation is created (via `ConversationStateMachine` entering `.initialized`):

1. The `VaultManager` is notified of the new conversation
2. It sends a `DeviceKeyShare` message to the Vault group containing the new key
3. Other devices receive the share via their Vault client stream and import it into their keychain

**Hook point:** `ConversationStateMachine` already has state transitions. Add a delegate/notification when a conversation is fully created with its keys saved.

## Phase 3: Device Pairing

### 3.1 Pairing flow (QR code)

**Device A (existing device, shows QR):**

1. User taps "Add Device" in settings
2. Creates a Convos invite for the Vault group (standard `InviteCoordinator.createInvite`)
3. Generates a random 6-digit confirmation code
4. Displays QR containing the invite URL
5. Waits for join request with matching confirmation code in metadata
6. On match: adds Device B to the Vault group, sends `DeviceKeyBundle` with all keys
7. 60-second timeout on the entire flow

**Device B (new device, scans QR):**

1. User taps "Pair with existing device" during onboarding (or in settings)
2. Scans QR code → parses invite URL → gets `SignedInvite`
3. Generates its own Vault key (if it doesn't have one) or uses existing
4. Sends join request via `InviteCoordinator.sendJoinRequest` with:
   - `profile: JoinRequestProfile(name: UIDevice.current.name)`
   - `metadata: ["confirmationCode": "<6-digit-code>", "deviceName": UIDevice.current.name]`
5. Displays the 6-digit code on screen for the user to enter on Device A
6. Waits for acceptance (being added to the Vault group)
7. Receives `DeviceKeyBundle` and imports all keys

### 3.2 Confirmation code verification

Device A's `processMessage` for the Vault invite checks:
1. Standard invite validation (tag, expiry, signature)
2. Metadata contains `confirmationCode`
3. Code matches the one displayed on Device A
4. Only then: add Device B to the Vault group

This prevents unauthorized access if someone else scans the QR.

### 3.3 Post-pairing key import

After Device B is added to the Vault group:

1. Device A sends a `DeviceKeyBundle` containing all keys in its keychain
2. Device B receives it, iterates over the keys, and for each:
   a. Saves to `KeychainIdentityStore`
   b. Creates an XMTP installation (`Client.create(account: key.signingKey, options: ...)`)
   c. The `InboxStateMachine` handles the new client normally

## Phase 4: Ongoing Sync

### 4.1 New conversation sync

When a device creates a new conversation:

1. `ConversationStateMachine` reaches `.initialized`
2. The identity (inboxId, clientId, keys) is already saved in `KeychainIdentityStore`
3. `VaultManager.shareKey(identity)` sends a `DeviceKeyShare` to the Vault group
4. Other devices' Vault clients receive the message via stream
5. Each device imports the key and creates an installation

### 4.2 Vault message streaming

The `VaultManager` runs a message stream on the Vault group:

```swift
func startKeyStream() async {
    for try await message in vaultGroup.streamMessages() {
        switch message.contentType {
        case ContentTypeDeviceKeyBundle:
            let bundle: DeviceKeyBundleContent = try message.content()
            await importKeys(from: bundle)
        case ContentTypeDeviceKeyShare:
            let share: DeviceKeyShareContent = try message.content()
            await importKey(from: share)
        case ContentTypeDeviceRemoved:
            let removed: DeviceRemovedContent = try message.content()
            await handleDeviceRemoval(removed)
        default:
            break
        }
    }
}
```

### 4.3 Deduplication

Keys may arrive multiple times (e.g., from multiple devices sharing simultaneously, or replaying history). Deduplication is by `(inboxId, conversationId)` — if the key already exists in the keychain, skip it. The keychain store's `save` will fail with a duplicate error which we catch and ignore.

## Phase 5: Device Management UI

### 5.1 Settings screen

**Location:** `Convos/App Settings/` — new section "Devices"

- Lists all members of the Vault group (each is a device)
- Shows device name (from profile display name)
- Shows "This device" badge for the current device's inbox
- "Add Device" button → pairing flow
- Swipe to remove a device → removes from Vault group, sends `DeviceRemoved` message
- Shows device count (e.g., "3 of 10 devices")

### 5.2 Onboarding integration

New user flow needs a branch:
- "Set up as new device" → creates Vault, normal onboarding
- "Pair with existing device" → scans QR, imports keys, skips conversation creation

## Implementation Order

1. **Protobuf field** — `conversationType` in `ConversationCustomMetadata`
2. **Content types** — `DeviceKeyBundle`, `DeviceKeyShare`, `DeviceRemoved` codecs + tests
3. **`VaultManager` core** — Create Vault, store key, connect client, share/import keys
4. **Key share hook** — Emit key share on conversation creation
5. **Pairing flow** — QR generation, scan, confirmation code, key bundle exchange
6. **Device management UI** — Settings screen for device list and removal
7. **Onboarding branch** — "Pair with existing device" option
8. **iCloud Keychain** — Vault key backup for same-Apple-ID recovery

## Files to Create/Modify

### New files
- `ConvosCore/Sources/ConvosCore/Vault/VaultManager.swift`
- `ConvosCore/Sources/ConvosCore/Vault/VaultKeyStore.swift` (Vault key in keychain, separate from conversation keys)
- `ConvosCore/Sources/ConvosCore/Custom Content Types/DeviceKeyBundleCodec.swift`
- `ConvosCore/Sources/ConvosCore/Custom Content Types/DeviceKeyShareCodec.swift`
- `ConvosCore/Sources/ConvosCore/Custom Content Types/DeviceRemovedCodec.swift`
- `Convos/App Settings/DeviceManagement/DeviceManagementView.swift`
- `Convos/App Settings/DeviceManagement/DeviceManagementViewModel.swift`
- `Convos/App Settings/DeviceManagement/AddDeviceView.swift`
- `Convos/App Settings/DeviceManagement/PairDeviceView.swift`

### Modified files
- `ConvosAppData/Sources/ConvosAppData/Proto/conversation_custom_metadata.proto` — add field 6
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` — register new codecs, Vault client options
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` — start VaultManager alongside session
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationStateManager.swift` — notify VaultManager on conversation creation
- `Convos/App Settings/AppSettingsView.swift` — add Devices section

## Open Questions for Implementation

1. **Should the Vault client share the same `InboxStateMachine` infrastructure or be completely separate?** The inbox state machine is designed for conversation inboxes with consent management, syncing, etc. The Vault is simpler — it just needs a client and message streaming. A lightweight wrapper might be better than reusing the full state machine.

2. **Where do Vault content types live?** They reference `KeychainIdentityKeys` which is in `ConvosCore`. Putting them in a separate package would require extracting the key types to `ConvosAppData`. Simpler to put them in `ConvosCore/Custom Content Types/` alongside `ExplodeSettingsCodec`.

3. **How does the Vault interact with conversation expiry?** The Vault group should never expire. Need to ensure the explode/expiry system checks `conversationType == "vault"` and exempts it.
