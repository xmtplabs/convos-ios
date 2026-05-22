# Device Pairing for Identity Sync — iOS Implementation Plan

> Supersedes the iCloud Keychain approach in PR #835 / `docs/plans/icloud-keychain-identity-sync.md`.
> Reuses pairing UX and handshake from the closed PR #564 (`docs/plans/convos-vault.md`), adapted for the single-inbox identity model.

## TL;DR

Replace automatic iCloud Keychain sync with an explicit, user-initiated **device pairing** flow. To put Convos on a second device, the user opens **Settings -> Devices -> Add new device** on Device A, scans the QR on Device B, exchanges a 6-digit PIN, confirms a 3-emoji fingerprint, and Device A securely transfers its signing key to Device B over an MLS-encrypted XMTP DM. After that, both devices share the same SIWE address, the same backend account, the same `inboxId`, and (per libxmtp) two distinct XMTP installations.

This is the **blocker for production TestFlight beta**: without it, IAP and per-account purchases don't carry across a user's devices.

## Why not iCloud Keychain sync

PR #835 makes the identity slot `kSecAttrSynchronizable = true`. This works in the happy path but has three properties we cannot ship to beta:

1. **Silent last-write-wins.** If a user installs Convos on two devices while iCloud Keychain is disabled (each device gets an independent identity), then enables iCloud Keychain, CKKS replicates one identity over the other. The losing device silently changes its identity to the winning device's. From the user's perspective, history, contacts, and inbox membership all break.
2. **No user consent moment.** The transfer happens invisibly minutes-to-hours after the second install. There is no point at which the user agrees that "Device B should be the same identity as Device A." Pairing requires both devices physically present and explicit human action on each.
3. **Recovery is impossible.** If iCloud Keychain corrupts or clobbers an identity, there is no fallback. With pairing, both devices keep the key independently; revoking a lost device is a deliberate action, not an accident.

PR #835 is not merged. The plan is to **close it** (or land only its non-sync parts: `MessagingService.installationsSnapshot` and `revokeOtherInstallations`, plus the `DebugInstallationsView`) and build pairing instead.

## Goals

- A second device on the same Apple ID can adopt the user's existing identity (same SIWE address, same `inboxId`, same backend `accountId`) without ever writing to iCloud Keychain.
- The handshake is MITM-resistant via reverse-PIN + co-presence emoji fingerprint.
- Identity material never leaves the device except over the XMTP MLS-encrypted DM between the two devices' inboxes.
- The flow is interruptible and recoverable. Failures put both devices back in a clean state, never a half-paired one.
- The Notification Service Extension keeps working on both devices without any extra coordination - it reads its local copy of the identity from the app-group keychain (`loadSync()`), same as today.

## Non-goals (for this PRD)

- Restoring identity after the only device is lost or wiped. Pairing requires the source device. A separate recovery story (BIP-39, social, or backend-relayed encrypted backup) is out of scope and will land later.
- Multi-device profile updates across devices. XMTP's history sync already replays profile messages; cross-device live profile broadcast is a follow-up.
- Cross-device conversation deletion sync (the `ConversationDeletedCodec` from PR #564). Defer.
- Multi-device read-state sync. XMTP doesn't sync read receipts across installations today; that's an XMTP-level feature, not pairing.

## Background: the current single-inbox identity

(See `docs/plans/single-inbox-identity-refactor.md` for the full refactor.)

What's in the keychain today (`KeychainIdentityStore.swift`):

```swift
public struct KeychainIdentity: Codable, Sendable {
    public let inboxId: String     // libxmtp-assigned
    public let clientId: String    // UUID, generated at register time
    public let keys: KeychainIdentityKeys
}

public struct KeychainIdentityKeys: Codable, XMTPClientKeys, Sendable {
    public let privateKey: PrivateKey   // secp256k1, the Ethereum signing key
    public let databaseKey: Data        // 256-bit random, local GRDB encryption
}
```

- **`privateKey`**: the user's Ethereum identity. Same value across devices => same SIWE address => same backend `accountId` => same XMTP `inboxId`. This is the only field that must be transferred during pairing.
- **`databaseKey`**: encrypts this device's local libxmtp database. Per-device; Device B generates its own.
- **`inboxId`**: derived from `privateKey` by libxmtp. Already determined by `privateKey`; we copy it forward as a sanity check.
- **`clientId`**: per-device UUID used for backend deviceId. Device B generates its own.

The XMTP **installation key** is not in `KeychainIdentity` at all - libxmtp manages it inside its encrypted SQLite DB. Each device gets its own installation under the same inbox. This is exactly what we want: paired devices are *peers* under one inbox, not clones.

**Transfer payload is therefore one field**: `privateKey` (32 bytes secp256k1). Everything else regenerates locally.

## Approach

Two devices, one new content type, one new ephemeral DM, one settings sheet, one onboarding deep-link entry point.

```
Device A (existing user)                       Device B (fresh install)
-----------------------------                  --------------------------------
Settings -> Devices -> Add device
  PairingCoordinator.start()
  -> createPairingInvite()                     opens https://convos.org/pair/<slug>
  shows QR + URL                  <----QR----  via Universal Link or scan
  url contains: SignedInvite slug,
   expires, initiator deviceName
                                               DeepLinkHandler routes to
                                                 OnboardingPairingSheet
                                               creates EPHEMERAL inbox
                                                 (no backend account, no JWT)
                                               sends PairingJoinRequest DM
                                                 to A's real inbox
  receives JoinRequest             <---DM---
  generates 6-digit PIN
  shows PIN on screen
  sends PairingMessage.pin DM      ---DM--->
                                               receives PIN
                                               renders PinEntryField
                                               user reads PIN off Device A
  receives pin echo                <---DM---   user types PIN, taps Submit
                                                 sends pinEcho DM
  verifies pin matches
  computes emojiFingerprint(A, B, pin)         computes same fingerprint
  shows 3 emojis + "Confirm"                   shows 3 emojis + "Waiting..."
  user taps Confirm
  sends IdentityShare DM           ---DM--->   receives IdentityShare
                                                 contains: privateKey bytes
                                               replaces local identity with
                                                 paired key, wipes ephemeral
                                                 inbox state, re-bootstraps
                                                 SessionStateMachine
                                               new libxmtp install registered
                                                 under existing inboxId
                                               first SIWE auth: backend
                                                 returns same accountId as A
  marks paired in DevicesView                  shows "Successfully paired"
  XMTP history sync replays                    XMTP history sync replays
  conversation state on B                      conversation state on B
```

### Why this is safe

- The QR/URL carries a `SignedInvite` slug bound to A's signing key (proves the QR was generated by *someone* who controls A's identity). A snooper who photographed the QR over A's shoulder learns nothing because:
- The PIN is generated *after* B sends the join request and travels A->B only. It's the joining device's job to read it from A's screen and echo it back. A physical attacker (shoulder-surfer with another device) would need to convince the legitimate user to type a PIN they can see on A's screen but the attacker can't.
- The 3-emoji fingerprint is computed locally on both ends from `SHA256(sort(inboxA, inboxBEphemeral) | ":" | pin)`. A MITM splicing between them would have a different `inboxBEphemeral`, so the emojis on A and B would not match. The user catches it visually.
- The actual key transfer rides on the XMTP DM (MLS, forward-secret) between A's real inbox and B's ephemeral inbox - end-to-end-encrypted; the backend never sees plaintext.

## Reuse map

What we **lift from PR #564 essentially verbatim**:

| File from #564 | Status |
|---|---|
| `ConvosCore/Sources/ConvosCore/Vault/PairingCoordinator.swift` | Lift the state machine, PIN generator, emoji fingerprint. Rename `vaultManager` dep -> `PairingService` protocol. Strip vault-group references. |
| `ConvosCore/Sources/ConvosCore/Vault/ContentTypes/PairingMessageCodec.swift` | Lift verbatim. Carries `pin`/`pinEcho`/`error`. |
| `Convos/Devices/PairingSheetView.swift` + `PairingSheetViewModel.swift` (initiator) | Lift. Replace `vaultManager` with `PairingService`. |
| `Convos/Devices/JoinerPairingSheetView.swift` + `JoinerPairingSheetViewModel.swift` (joiner) | Lift. Same dependency swap. Adds the onboarding entry path (see below). |
| `Convos/Devices/DevicesView.swift` + `DevicesViewModel.swift` | Lift but trim: no "vault" terminology, just "Other devices on this account". |
| `Convos/Devices/{ExpiryLabel,RotatingSyncIcon}.swift` and `HoldToRevealButton`, `PinEntryField` | Lift verbatim. Pure SwiftUI. |
| `Convos/DeepLinking/DeepLinkHandler.swift` `.pairDevice` case + URL extensions | Lift verbatim. |
| QA test `qa/tests/26-pair-device.md` and structured YAML | Lift, scope down to single-key (remove "8 conversations synced" criteria; XMTP history sync handles that). |

What we **discard from PR #564**:

- All of `ConvosCore/Sources/ConvosCore/Vault/` except `PairingCoordinator.swift` and `PairingMessageCodec.swift`. Specifically: `VaultManager`, `VaultClient`, `VaultKeyCoordinator`, `VaultHealthCheck`, `VaultImportSyncDrainer`, `VaultDeviceManager`, `VaultManager+Archive`, `VaultSessionIntegration`, `VaultInviteClientAdapter`, `VaultMessageProcessorProtocol`, `VaultServiceProtocol`.
- `DeviceKeyBundleCodec`, `DeviceKeyShareCodec`, `DeviceRemovedCodec`, `ConversationDeletedCodec`.
- `VaultKeyStore`, the separate keychain service.
- `DBInbox.isVault`, `DBInbox.sharedToVault`, `DBVaultDevice`, `VaultDeviceRepository`, `VaultDeviceWriter`, the related migrations.
- `requestDeviceSync()`, `scheduleDelayedDiscovery()`, and the post-authorization hooks in `SessionManager`/`InboxStateMachine`.

What is **new in this PRD**:

- `IdentityShareCodec` (replaces `DeviceKeyBundleCodec`). Tiny: carries one secp256k1 private key plus metadata.
- `PairingService` protocol. Thin actor that wraps the two surfaces the coordinator needs: "send a DM from my real inbox to inbox X" (initiator side) and "send a DM from my ephemeral inbox to inbox Y" (joiner side).
- Joiner-side bootstrap: spin up an **ephemeral XMTP client** (no backend auth, no SIWE, no `KeychainIdentityStore` write) just long enough to receive the key, then tear it down and re-bootstrap with the paired key.
- Onboarding entry path: when the app is launched cold by a `convos://pair/...` deep link on a device with no identity, route to the joiner sheet *before* silent identity creation runs.

## Cryptographic protocol

### Phase 1 — Invite

Device A:

1. `PairingCoordinator.startPairing()` calls `pairingService.createInvite(initiatorInboxId:)`.
2. The service constructs a `SignedInvite` via the existing `ConvosInvites` package, signed with A's `KeychainIdentity.keys.privateKey`. The slug carries: signer pubkey (recoverable), expiry (60s default), an "invite tag" (single-use), and a fresh ephemeral group ID *or* (preferred for simplicity) just a random nonce - we don't need a real group for the handshake DM. Spec the simpler shape: slug encodes signer + nonce + expiry + single-use tag.
3. URL: `https://<domain>/pair/<slug>?expires=<unix>&name=<percent-encoded-device-name>`.
4. UI renders the URL as a QR (blurred by default, hold-to-reveal) and as a `ShareLink`.

### Phase 2 — Joiner connects

Device B, on receiving the deep link or scanning the QR:

1. Parses URL via `DeepLinkHandler.convosPairingId`. If the slug is malformed or expired, abort with `.invalidInviteSlug` UI.
2. Validates `SignedInvite` signature, recovers A's signing pubkey (proves the QR came from a real Convos identity).
3. Spins up an **ephemeral XMTP client** (see *Joiner ephemeral bootstrap* below) and reads `inboxIdEphemeral` from it.
4. Sends `PairingJoinRequest` DM to A's real inbox. Payload: `{ initiatorInboxId, joinerInboxId: inboxIdEphemeral, deviceName: DeviceInfo.deviceName, slug }`.
5. Starts a DM stream from A's real inbox to listen for the PIN.

### Phase 3 — Reverse PIN

Device A's coordinator (already streaming DMs on its real inbox):

1. Filters incoming DMs for `PairingJoinRequest` content matching the active pairing session.
2. Generates `pin = 6 random digits`. Stores it in coordinator state. Transitions to `showingPin`.
3. Sends `PairingMessageContent.pin(pin)` DM to `joinerInboxId` (B's ephemeral inbox).

Device B's UI:

1. Receives `pin` on its DM stream. Transitions UI to `pinEntry`.
2. User reads the PIN off A's screen and types it.
3. B sends `PairingMessageContent.pinEcho(pin)` DM back to A's real inbox.

Device A's coordinator:

1. Receives `pinEcho`. Compares to `generatedPin`.
2. Mismatch -> `PairingError.invalidConfirmationCode`, send `.error` DM to joiner, transition to `failed`. UI shows "The confirmation code does not match."
3. Match -> transition to `waitingForEmojiConfirmation`.

### Phase 4 — Emoji fingerprint

Both sides compute locally and identically:

```swift
public static func emojiFingerprint(inboxA: String, inboxB: String, pin: String) -> [String] {
    let sorted = [inboxA, inboxB].sorted()
    let combined = sorted.joined(separator: ":") + ":" + pin
    let hash = SHA256.hash(data: Data(combined.utf8))
    let bytes = Array(hash)
    return (0..<3).map { i in
        EmojiSelector.emojis[Int(bytes[i]) % EmojiSelector.emojis.count]
    }
}
```

(Identical to PR #564.)

- Device A shows 3 emojis + a **Confirm** button + copy "Make sure these emoji match on `<B.deviceName>` before confirming."
- Device B shows 3 emojis + "Waiting for confirmation..." copy. **No button on B** - confirmation is unilateral, on A only. This is correct: B doesn't know whether A actually pressed Confirm, but A is the side that authorizes the transfer.

### Phase 5 — Identity transfer

User taps **Confirm** on Device A.

1. A's coordinator builds `IdentityShareContent`:

   ```swift
   struct IdentityShareContent: Codable {
       let schemaVersion: UInt32      // 1
       let privateKeyData: Data       // 32 bytes secp256k1
       let inboxId: String            // for client-side sanity check on B
       let issuedAt: Int64            // unix seconds
       let initiatorClientId: String  // info only; not authoritative on B
   }
   ```

   `databaseKey` is **not** transferred - B generates a fresh one. Backend `accountId` is **not** transferred - B re-derives it via SIWE.

2. A sends this as a DM from real-A to B-ephemeral using `IdentityShareCodec`. Transitions UI to `syncing`.
3. B receives it on its DM stream. Cancels its other listeners. Transitions UI to `syncing` (sheet non-dismissible).
4. B validates: `recoverAddress(privateKeyData) == addressInSignedInvite`. If mismatch -> `failed`, do not proceed.
5. B writes to keychain: `KeychainIdentityStore.save(inboxId: <from share>, clientId: UUID(), keys: KeychainIdentityKeys(privateKey: PrivateKey(privateKeyData), databaseKey: <new random>))`.
6. B tears down the ephemeral XMTP client (drops local DB, drops in-memory state).
7. B re-bootstraps `SessionManager` -> `SessionStateMachine.handleAuthorize` (not `handleRegister`) with the now-present identity. libxmtp detects the existing `inboxId` on the XMTP network and adds B's new installation under it.
8. B runs SIWE auth against the backend with the paired key; backend returns the **existing** `accountId` for that address. IAP and any other account-scoped state is now reachable.
9. B's UI transitions to `completed`. Sheet shows "Successfully paired", Got it button dismisses.
10. XMTP history sync begins replaying conversations on B in the background.

### Phase 6 — Failure DMs

If A's coordinator transitions to `failed` for any reason after the join request, it sends `PairingMessageContent.error(message)` to B so B isn't left spinning. Same in reverse: B can send `.error` if it can't validate the received key.

The 1.5-second `Task.sleep` in PR #564's `JoinerPairingSheetViewModel.onPairingCompleted` was flagged by Macroscope review for a race (an error arriving during the sleep is overwritten by completion). **Remove the sleep** in our port. The transition `syncing -> completed` should happen after B has actually saved and re-bootstrapped, not after a UX delay.

## State machines

### Initiator (`PairingState` in `PairingCoordinator`)

```swift
public enum PairingState: Sendable, Equatable {
    case idle
    case generatingInvite
    case waitingForScan(inviteURL: String, expiresAt: Date)
    case showingPin(pin: String, joinerDeviceName: String, joinerInboxId: String)
    case waitingForEmojiConfirmation(emojis: [String], joinerInboxId: String)
    case sharingIdentity        // replaces #564's addingDevice + sharingKeys
    case completed(joinerDeviceName: String)
    case failed(PairingError)
    case expired
}

public enum PairingError: Error, LocalizedError {
    case notConnected
    case invalidInviteSlug
    case invalidConfirmationCode
    case pairingTimeout
    case alreadyPairing
    case identityShareSendFailed(String)
    case addressMismatch
}
```

Transition table is the same as #564 with `.addingDevice` and `.sharingKeys` collapsed into `.sharingIdentity`. The 60-second expiration timer is restarted on entry to `waitingForScan`, `showingPin`, and `waitingForEmojiConfirmation`. Later states are immune (you don't want a fingerprint timeout to fire while the key is in flight).

### Joiner (`JoinerPairingFlowState`)

```swift
enum JoinerPairingFlowState: Equatable {
    case connecting              // sending join request, awaiting PIN
    case pinEntry(initiatorInboxId: String)
    case waitingForEmoji(emojis: [String])
    case receivingIdentity       // identity share inbound
    case completed
    case failed(String)
    case expired
}
```

## UI

### Settings entry — Devices screen

Add to `AppSettingsView.swift` a `Devices` row (icon `iphone.gen3.sizes`, footer "Manage and pair other devices"). NavigationLink -> `DevicesView`. Lifted from #564 with these trims:

- Drop "vault" terminology entirely.
- The list shows: a row for "This device" (use `DeviceInfo.deviceName` + `iphone.gen3` icon, subtitle "This device"), then one row per other paired installation (queried via `MessagingService.installationsSnapshot`).
- Each non-self row supports swipe-to-delete and a Delete context menu, which opens `RemoveDeviceSheetView` (from #564) with a 3-second hold-to-confirm. On confirm, call `MessagingService.revokeInstallation(installationId:)` (extension of `revokeOtherInstallations` from #835 to support targeted revocation). Capture the installation timestamp from `MessagingService.installationsSnapshot.installations` so the list isn't blank between revocation and refresh.
- Empty state ("No other devices") + "Add new device" button as in #564.

### Initiator sheet — `PairingSheetView`

Six states, all lifted from #564 essentially verbatim, with the following changes:

- Title in `.sharingIdentity` says "Pairing..." (was "Syncing keys..."). Sub-copy: "Transferring your identity to `<B.deviceName>`."
- Title in `.completed` says "Device added", same `iphone.badge.checkmark` icon.
- Drop the post-completion `.shareAllKeys()` step and corresponding sub-state; we ship one key over one DM.

QR rendering, hold-to-reveal, expiry label, share link, PIN display, emoji confirmation are unchanged from #564.

### Joiner sheet — `JoinerPairingSheetView`

Same six states (`connecting`, `pinEntry`, `waitingForEmoji`, `receivingIdentity`, `completed`, `failed`/`expired`). Trim:

- Remove the 1.5s sleep in `onPairingCompleted` (Macroscope race). Transition to `.completed` happens after the identity is actually saved and the new client has bootstrapped.
- In `.receivingIdentity`, copy reads "Adopting your identity..." while the rotating sync icon plays. Sheet is non-dismissible.
- In `.completed`, copy reads "Successfully paired". Primary "Got it" dismisses.

### First-launch onboarding integration

PR #564 only had a Settings entry, because the joiner already had an account. In our world the joiner is typically a fresh install with no identity. Add an **onboarding entry point** for the joiner:

- When the app is launched (cold or warm) with a `convos://pair/...` URL or a Universal Link matching `/pair/`, `SceneURLStorage` stores it as a pending deep link.
- In `ConvosApp.onAppear` / `ContentView.task`, if a pending pair URL exists *and* `KeychainIdentityStore.loadSync()` returns nil (no existing identity), do not auto-create an identity. Instead, present the `JoinerPairingSheetView` modally over the empty `ConversationsView`.
- The sheet's `JoinerPairingSheetViewModel` does the ephemeral-client bootstrap and PIN exchange. Only after `.completed` does normal app startup proceed - now with the paired identity in the keychain, `SessionManager.loadOrCreateService` reads it via `loadSync()` and reaches `handleAuthorize`.

Optional but recommended for clarity at TestFlight beta: also add a "I already use Convos on another device" affordance on the first-launch ConversationsView empty state, which opens a camera scanner. Scope decision: defer scanner UI to follow-up; the deep-link entry from the QR on Device A's `ShareLink` ("Copy link" -> AirDrop / Messages -> tap on B) is sufficient for beta.

## Joiner ephemeral bootstrap

The joiner needs an XMTP inbox *briefly* to send the join request, receive the PIN, send pin-echo, and receive the identity share - then it must throw all of that away cleanly. Two paths considered:

**Option A — Full SessionStateMachine with placeholder identity** (cleaner but with a quirk):

Run `handleRegister` end-to-end as today: generate a random `KeychainIdentityKeys`, build an XMTP `Client`, register the inbox on the network. **Skip backend SIWE auth in this mode.** When pairing completes, call `SessionManager.deleteAllInboxes()` to wipe local state, delete the keychain slot, then write the paired identity and call `handleAuthorize`. Risk: creates an orphan inbox on the XMTP network (no installations after teardown). Acceptable for beta - XMTP inboxes without installations are inert.

**Option B — Minimal pairing-only XMTP client** (more code, no orphan inbox):

Add a new `PairingClient` actor that wraps libxmtp's create/streamDMs/sendDM without going through `SessionStateMachine`. Uses a separate keychain slot (`org.convos.ios.PairingEphemeral.v1`) so a crash mid-pairing doesn't corrupt the real identity slot. On completion, the entire ephemeral SQLite DB and keychain slot are torn down. The resulting orphan inbox still exists on the network (libxmtp can't "uncreate" it), so the orphan-inbox concern from A is the same. The advantage is process isolation: a half-finished pairing can't pollute the real identity flow.

**Recommendation: Option A**, gated by a `PairingMode` flag passed into `SessionStateMachine` that:

- Skips `authenticateBackend` (no SIWE, no JWT, no backend account).
- Skips `notificationToken` registration.
- Marks the keychain slot as `pairing-only` via a new field on `KeychainIdentity` (e.g. `purpose: KeychainIdentityPurpose = .live | .pairing`).

This keeps one code path, makes the placeholder explicit, and keeps the keychain layout consistent.

When pairing completes:

1. Tear down `MessagingService` for the placeholder.
2. Call `MessagingService.stopAndDelete()` (already exists per #835).
3. `identityStore.delete()` to remove the placeholder keychain slot.
4. `identityStore.save(...)` with the paired identity (`purpose: .live`).
5. `SessionManager.loadOrCreateService()` runs again, now finds the live identity, takes the `handleAuthorize` path.

## IdentityShareCodec

New file: `ConvosCore/Sources/ConvosCore/Pairing/ContentTypes/IdentityShareCodec.swift`.

```swift
public struct IdentityShareContent: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let privateKeyData: Data
    public let inboxId: String
    public let issuedAt: Int64
    public let initiatorDeviceName: String?
}

public final class IdentityShareCodec: ContentCodec {
    public typealias T = IdentityShareContent
    public let contentType = ContentTypeID(authorityId: "org.convos", typeId: "identityShare",
                                            versionMajor: 1, versionMinor: 0)
    // ... encode/decode via JSONEncoder/JSONDecoder
}
```

Notes:

- This codec is **only ever sent over a pairing DM**. Treat any inbound `IdentityShareContent` outside an active pairing handshake as an error (drop it, log a Sentry warning - this should not happen, but if it does, it's malicious).
- Do not register this codec on the real XMTP client. Only the ephemeral pairing client (joiner side) and the initiator's real client during an active pairing session need to encode/decode it.
- Validate `privateKeyData.count == 32` and that the recovered address matches the address recovered from the `SignedInvite` slug. If not, transition to `.failed`.

## Failure and edge-case checklist

| Scenario | Behavior |
|---|---|
| QR expires before B scans | B's URL parse sees `expires < now` -> failed sheet "Pairing expired." |
| B sends `JoinRequest` but A is offline | A's stream picks it up when A comes back. As long as the slug hasn't expired (60s), pairing proceeds. If expired, A returns to idle on receipt. |
| User types wrong PIN | `.invalidConfirmationCode` on A; A sends `.error` DM; B's UI shows "The confirmation code does not match." Dismiss returns both to idle. |
| Two devices scan A's QR (race) | The invite is `singleUse: true`. The first `JoinRequest` consumed by A locks the session; subsequent join requests are rejected with `.error`. |
| A force-quits during PIN display | B's countdown expires, B shows "Pairing expired." When A relaunches, coordinator finds no in-flight session (transient state isn't persisted). User starts over. |
| B force-quits after PIN echo | A's `waitingForEmojiConfirmation` timer expires. A shows "Pairing expired." A sends no further DMs. |
| Identity share DM dropped by network | A's `sharingIdentity` has no timer (the user already confirmed). If the send fails, transition to `.failed`. Need: a retry-on-send-failure with backoff, max 3 attempts over ~5 seconds, before transitioning to `.failed`. |
| B receives `IdentityShareContent` but address mismatches `SignedInvite` signer | `.failed` with copy "Pairing rejected: identity mismatch." Do not save anything. |
| B already has a `live` identity (user pairs with a different account) | This is the dangerous case. Refuse pairing: show "This device already has a Convos identity. Delete data first to pair with a different account." Block by checking `identityStore.loadSync()?.purpose == .live` in the joiner sheet's `task`. |
| iCloud Keychain is on at the OS level | Irrelevant. Our keychain slot has `kSecAttrSynchronizable = false` (we revert PR #835's change). The OS-level iCloud Keychain setting cannot promote our slot. |
| User reinstalls Convos on the same device | Keychain is cleared on uninstall (`kSecAttrAccessibleAfterFirstUnlock` items survive only as long as the app is installed). User must pair again or onboard fresh. |

## Migration from PR #835

PR #835 is not merged. Action: **close it** (or rebase to keep only the non-sync parts):

- Keep: `BackendAuthProbe.Status.identityStorage`, `IdentityStorageLocation`, `DebugInstallationsView`, `MessagingService.installationsSnapshot(refreshFromNetwork:)`, `MessagingService.revokeOtherInstallations()`. These are useful for our DevicesView.
- Discard: the `v4-synced` keychain slot, the legacy-to-synced migration in `load()`, the `synchronizable: true` write path.

If any TestFlight build of #835 is in the wild (the PR notes "Live multi-device verification" was run), users who installed that build have their identity in `v4-synced`. They will need a one-time read-then-rewrite migration on first launch of the pairing build: `loadFromSyncedSlot() -> writeToLocalSlot() -> deleteSyncedSlot()`. Implement only if any beta tester is known to be on a #835 build. Otherwise no migration needed.

## Testing strategy

### Unit tests — `ConvosCoreTests`

- `PairingCoordinatorTests` (lift from #564). Cover the full state machine including timeouts, invalid PIN, and `.error` notifications.
- `IdentityShareCodecTests`: encode/decode roundtrip, version mismatch handling, `privateKeyData.count != 32` rejection.
- `EmojiFingerprintTests`: identical hash on both orderings, deterministic across runs, different PIN -> different emojis.
- `KeychainIdentityStoreTests`: assert the slot remains `kSecAttrSynchronizable = false`. Add a regression test that fails if anyone flips it back. Add `purpose` field tests if Option A above is taken.

### Integration tests

- `PairingIntegrationTests`: spin up two XMTP clients in-process (using libxmtp's test harness, same pattern as `VaultIntegrationTests` in #564). Exercise the full handshake including identity share. Verify that after pairing, both clients resolve to the same `inboxId` and that B's client lists A's installation alongside its own.
- Negative tests: wrong PIN, expired slug, address mismatch on the share, double join request.

### Manual QA — `qa/tests/26-pair-device.md` and `qa/tests/structured/26-pair-device.yaml`

Lift PR #564's QA test. Trim criteria:

- Drop "Device B sees Device A's 8 conversations within 30 seconds" (XMTP history sync is independent; cover separately).
- Keep: blurred QR + hold-to-reveal, deep link routing, PIN visible on A and entered on B, identical emojis on both, both transition through `syncing` to `completed`, both list each other in DevicesView post-pair.
- Add: backend `account-auth-check` returns the same `accountId` on both devices after pairing. This is the IAP-blocker proof point and the goal of the entire feature.
- Add: revoking Device B from A's DevicesView causes B's next `account-auth-check` to fail with a recognizable error (installation revoked).

QA event for log extraction: `QAEvent.emit(.pairing, "pairing_url_created", ["url": inviteURL])` (rename namespace from `.vault`).

## Delivery

Single PR off `dev`. TestFlight-beta-blocking, so it ships as one reviewable unit:

- Close PR #835 (or cherry-pick `installationsSnapshot` / `revokeOtherInstallations` / `DebugInstallationsView` into this PR, drop the synchronized-keychain change).
- Land `PairingCoordinator`, `PairingMessageCodec`, `IdentityShareCodec`, `PairingService` protocol, `EmojiFingerprint`, `PairingMode` plumbing in `SessionStateMachine`, the full UI (`DevicesView`, both pairing sheets, supporting primitives), `DeepLinkHandler` routing, onboarding gate, QA test 26 and structured YAML, integration tests.

Build order inside the PR (so each commit compiles and tests pass for bisect-friendliness, even though they're not separately reviewed):

1. Revert #835's `kSecAttrSynchronizable` change; land the non-sync helpers.
2. Pairing core (coordinator, codecs, service protocol, fingerprint, `PairingMode` flag).
3. Pairing UI + deep link routing.
4. Onboarding gate.
5. QA test, integration tests, copy and accessibility pass.

## Out of scope (named for clarity)

- Recovery without the source device. The user needs Device A *with the identity in its keychain* to pair Device B. If A is lost, the identity is gone. This is the same property as Signal pre-secure-value-recovery, and acceptable for beta. Track follow-up: backend-relayed encrypted backup with a user-chosen passphrase or BIP-39.
- Multi-device profile sync, multi-device read receipts, cross-device conversation deletion sync.
- A native camera scanner for the joiner. The Universal Link flow (tap the URL on B's device) is sufficient. Add scanner in a follow-up.
- IAP-restore UX. Apple's StoreKit handles transaction restore via Apple ID; once both devices are on the same `accountId` post-pair, our backend's IAP entitlement resolves the same on both. No additional iOS-side work required for the pairing PR, but the IAP team should verify the round-trip end-to-end before TestFlight beta cuts.
- Device naming UX (rename a paired device). Defer.

## Known limitations (acceptable for TestFlight; flagged for follow-up)

### Private key at rest in history-synced DM

`IdentityShareContent` carries the raw secp256k1 private key inside a normal MLS DM (`findOrCreateDm` between the initiator's real inbox and the joiner's ephemeral inbox). libxmtp ships with `deviceSyncEnabled: true` (see `SessionStateMachine.clientOptions`), which replicates message history across all installations under an inbox via XMTP's history server. After the joiner adopts the paired identity, both installations sit under the *same* inbox — so the original IdentityShare DM (from the *ephemeral* inbox era) lives encrypted on the history server *and* in every paired installation's persistent SQLCipher DB indefinitely. The encryption is MLS-grade; the practical concern is "any future paired device or anyone with the inbox's MLS keying material can decrypt a message containing the secp256k1 signing key."

Why we shipped it anyway:
- Anyone who can decrypt that DM already has the inbox's MLS keys, which means they already have access to all of the user's conversations — possessing the secp256k1 key in addition gives no extra access in practice.
- The library doesn't currently expose an "ephemeral, no-store" content type. Building one is a real chunk of work in libxmtp.

Follow-up: when libxmtp exposes a non-persistent message type, switch `IdentityShareCodec` to it and clean up any existing DMs on receipt. Track this with the libxmtp team.

### Orphan backend `accountId` from cold-launch pair

If the user taps a `/pair/<slug>` deep link on a brand-new install *during* the silent-identity-creation window (a few hundred ms between `ConvosApp.init` finishing and `ConversationsView` becoming interactive), the placeholder identity completes its SIWE auth against the backend, registers an `accountId` keyed on the placeholder's wallet address, and subscribes to push topics for the placeholder inbox. Pairing then replaces the keychain identity, `refreshAfterPairingCompleted` clears the cached `MessagingService`, and the next backend auth runs SIWE under the *paired* address, returning the paired `accountId`. The placeholder `accountId` is now orphaned: no live device authenticates against it, no installations under its inbox can decrypt anything, push topic subscriptions are dead-ended.

Practical impact:
- No user-visible data loss; the user only ever sees the paired account.
- Backend storage cost is one extra `account` row + a few `notifications_subscription` rows per cold-launch pair.
- Push delivery: the placeholder topics are subscribed to from the device's APNs token before pair; after pair, the device re-registers under the paired account. The orphan subscriptions point at an inbox no installation can serve, so any push that ever lands on them is silently dropped — not a delivery regression for the user, just dead routing on the backend.

Follow-up — two complementary paths, do at least one:
- iOS: pre-identity onboarding gate. When `ConvosApp.init` sees a `/pair/<slug>` URL in the launch options, set a `SessionManager` flag that short-circuits `loadOrCreateService()` to the failed-keychain branch until either the joiner sheet completes pairing or the user dismisses it. This is task #20 from the original plan; deferred because the `hasAnyUsedConversations` gate already handles the *data-loss* case, but it doesn't prevent the orphan account.
- Backend: GC accounts with zero active installations after a grace period (e.g. 7 days). The same logic would handle other orphan cases (deleted-all-data, multi-region replay, etc.) and removes the need for the iOS-side gate.

Until either lands, expect one orphan `accountId` per fresh-install-and-pair sequence.
