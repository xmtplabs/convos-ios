# ADR 002: Per-Conversation Identity Model with Privacy-Preserving Push Notifications

> **Status**: Superseded (in progress) — see `docs/plans/single-inbox-identity-refactor.md`.
> Single-inbox replacement is landing incrementally in the checkpoint commits that make up
> that plan. Full supersession (and the companion "ADR 011 – Single-Inbox Identity Model")
> lands at C14 once the refactor is behaviorally complete. The sections below remain the
> source of truth for the old code paths still present on this branch; amended sections at
> the bottom of the file note which checkpoint retired each piece.

## Context

Convos is a privacy-focused messaging app built on XMTP. Traditional messaging apps use a single identity per user, which creates several privacy concerns:

- All conversations can be linked to a single user identity
- User activity across conversations can be tracked and correlated
- Compromising one identity exposes all conversations
- Push notification infrastructure sees the user's actual messaging identity

Additionally, exposing XMTP inbox IDs to external services (like push notification backends) creates privacy risks, as these identifiers could be correlated across conversations or leaked in the event of a backend compromise.

## Decision

We implemented a **per-conversation identity architecture** where each conversation gets its own unique XMTP inbox identity. Private keys are stored securely in the iOS Keychain, and a separate `clientId` serves as a privacy-preserving identifier for push notification routing.

### 1. Per-Conversation Identity Model

Each conversation is associated with a unique XMTP inbox identity, providing complete conversation isolation.

**Key Principle:**
One XMTP inbox = One conversation. No identity is ever reused across multiple conversations.

**Implementation Overview:**

**Identity Creation Flow:**

1. **Pre-creation Cache**: XMTP inboxes are proactively created in the background to eliminate conversation creation latency (see ADR 003 for details)
2. **Inbox Consumption**: When a user creates a conversation, a pre-created inbox is consumed
3. **Registration**: A new XMTP client is initialized with fresh cryptographic keys (secp256k1 private key + 256-bit database encryption key)
4. **Storage**: The inbox identity and keys are saved to both the keychain and local database

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift`

**Database Model:**

Each inbox has a one-to-one relationship with its conversation:

```swift
struct DBInbox {
    let inboxId: String   // XMTP inbox identifier
    let clientId: String  // Privacy-preserving local identifier
    let createdAt: Date

    // One-to-one relationship
    static let conversations: HasManyAssociation<DBInbox, DBConversation>
}

struct DBConversation {
    let id: String
    let inboxId: String       // Foreign key to DBInbox
    let clientId: String      // Denormalized for efficient lookup
    // ...
}
```

**Invariant Enforcement:**

The `InboxWriter` enforces a critical invariant: `clientId` must never change for a given `inboxId`. Attempting to save an inbox with a mismatched clientId throws an `InboxWriterError.clientIdMismatch`, indicating data corruption or a bug.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBInbox.swift`, `ConvosCore/Sources/ConvosCore/Storage/Writers/InboxWriter.swift`

### 2. Secure Keychain Storage

Private keys for each XMTP identity are stored in the iOS Keychain with security-focused attributes.

**Stored Data Structure:**

```swift
struct KeychainIdentity {
    let inboxId: String    // XMTP inbox identifier
    let clientId: String   // Privacy-preserving local identifier
    let keys: KeychainIdentityKeys
}

struct KeychainIdentityKeys {
    let privateKey: PrivateKey  // secp256k1 signing key
    let databaseKey: Data       // 256-bit key for XMTP database encryption
}
```

**Security Attributes:**

- **Access Control**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  - Keys become available after the device is unlocked once
  - Keys never migrate to other devices via iCloud Keychain
  - Provides security even if the device is stolen while locked

- **App Group Access**: Keys stored in an app group keychain (`group.convos.keychain`) to allow the Notification Service Extension to access them for decrypting messages

- **Unique clientId Enforcement**: The keychain store enforces clientId uniqueness to prevent duplicate identities

**Key Generation:**

- **Private Key**: Generated using XMTP SDK's `PrivateKey.generate()` (secp256k1)
- **Database Key**: 256-bit random key generated using `SecRandomCopyBytes` for XMTP's local database encryption

**Location:** `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift:390-406`

### 3. ClientId: Privacy-Preserving Push Notification Routing

The `clientId` is a locally-generated UUID that serves as a privacy layer between XMTP inbox IDs and external services.

**Design:**

```swift
/// A client identifier used to anonymize inbox IDs when communicating with the backend.
/// This provides privacy by not exposing the actual XMTP inbox ID to external services.
public struct ClientId {
    public let value: String  // UUID string

    public static func generate() -> ClientId {
        return ClientId(value: UUID().uuidString)
    }
}
```

**Push Notification Flow:**

1. **Topic Subscription**: When subscribing to push notifications, the app sends `clientId` (not `inboxId`) to the backend:
   ```swift
   func subscribeToTopics(deviceId: String, clientId: String, topics: [String])
   ```

2. **Incoming Notification**: Push notification payload includes `clientId` for routing:
   ```swift
   class PushNotificationPayload {
       let clientId: String?  // Used to identify which inbox should handle this
       let notificationData: NotificationData?
       let apiJWT: String?    // JWT for API calls during processing
   }
   ```

3. **Inbox Lookup**: The Notification Service Extension uses `clientId` to query the keychain and retrieve the correct identity:
   ```swift
   func identity(forClientId clientId: String) throws -> KeychainIdentity
   ```

**Privacy Guarantee:**

The push notification backend only ever sees:
- `deviceId`: Apple's device push token
- `clientId`: A random UUID with no intrinsic meaning
- XMTP topic strings (conversation-specific, not identity-specific)

**The backend never sees the actual XMTP `inboxId`**, protecting user privacy even if the backend is compromised or subpoenaed.

**Location:** `ConvosCore/Sources/ConvosCore/Utilities/ClientId.swift`, `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift:461-477`

### 4. XMTP Client Configuration

Each XMTP client is independently configured:

- **Database Encryption**: Uses the stored `databaseKey` for local database encryption
- **Content Codecs**: Text, replies, reactions, attachments, group updates, etc.
- **Device Sync Disabled**: Each conversation is independent, no cross-device sync needed
- **API Configuration**: Environment-specific XMTP network endpoints

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift:880-916`

### 5. Cleanup on Deletion

When an inbox is deleted, comprehensive cleanup ensures no traces remain:

1. Unsubscribe from push notification topics
2. Unregister installation from backend
3. Delete all database records (messages, members, invites, conversations, activity)
4. Delete keychain identity
5. Delete XMTP local database files from disk

This ensures complete data removal when a conversation is deleted.

## Consequences

### Positive

- **Strong Privacy**: Conversations cannot be linked or correlated by external observers
- **Conversation Isolation**: Compromising one identity doesn't expose other conversations
- **No Central Identity**: No single "user identity" to track or compromise
- **Push Notification Privacy**: Backend never sees actual XMTP identities, only random UUIDs
- **Independent Lifecycle**: Each inbox can be independently managed, started, stopped, or deleted (see ADR 003)
- **Optimized UX**: Pre-creation cache provides instant conversation creation (see ADR 003)
- **Secure Storage**: iOS Keychain with device-only access control protects private keys
- **Data Isolation**: Each XMTP database is encrypted with a unique key

### Negative

- **Storage Overhead**: Multiple XMTP databases (one per inbox) consume more disk space than a single database
- **Memory Pressure**: Managing multiple active XMTP clients requires careful memory management (see ADR 003)
- **Complexity**: Significantly more complex state management than single-identity architectures (see ADR 003)
- **Key Management**: Multiple private keys to secure and potentially back up
- **Data Loss Risk**: If keychain is cleared (e.g., device restore without backup), all identities are permanently lost

### Mitigations

1. **Inbox Lifecycle Management**: LRU eviction and capacity limits manage memory pressure (see ADR 003)
2. **Pre-creation Cache**: Hides the latency cost of creating new XMTP clients (see ADR 003)
3. **State Machines**: `InboxStateMachine` and `ConversationStateMachine` provide well-defined lifecycle management
4. **Actor Isolation**: Swift actors prevent data races across concurrent inbox operations
5. **Device-Only Keys**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` ensures keys are device-bound and secure

### Security Model

| Threat | Mitigation |
|--------|------------|
| Cross-conversation correlation | Unique XMTP inbox per conversation |
| Push notification privacy leak | ClientId indirection layer hides inbox IDs |
| Backend compromise | Backend never sees XMTP inbox IDs, only random clientIds |
| Private key exposure | iOS Keychain with device-only access control |
| Database snooping | Per-inbox database encryption with unique keys |
| Device theft (locked) | Keys inaccessible until first unlock |
| Identity compromise | Isolated to single conversation |
| Timing correlation | LRU eviction and background pre-creation reduce timing signals |

## Related Files

**Identity Management:**
- `ConvosCore/Sources/ConvosCore/Auth/Keychain/KeychainIdentityStore.swift` - Keychain storage
- `ConvosCore/Sources/ConvosCore/Utilities/ClientId.swift` - ClientId definition

**Database Models:**
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBInbox.swift` - Inbox database model
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift` - Conversation model
- `ConvosCore/Sources/ConvosCore/Storage/Writers/InboxWriter.swift` - Invariant enforcement

**XMTP Integration:**
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` - XMTP client creation and configuration

**Push Notifications:**
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift` - Topic subscription with clientId
- `ConvosCore/Sources/ConvosCore/Push/PushNotificationPayload.swift` - Notification payload parsing

**Related ADRs:**
- ADR 003: Inbox Lifecycle Management (for pre-creation cache, LRU eviction, sleep/wake patterns)
- ADR 004: Explode Feature (explains how destroying an inbox destroys the conversation's cryptographic identity)
- ADR 005: Member Profile System (per-conversation identities enable per-conversation profiles via ProfileUpdate messages)

## References

- XMTP Protocol: https://xmtp.org
- iOS Keychain Services: https://developer.apple.com/documentation/security/keychain_services
- secp256k1 Elliptic Curve: https://www.secg.org/sec2-v2.pdf
- Swift Concurrency (Actors): https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html

## Single-Inbox Supersession Amendments

The single-inbox identity refactor (`docs/plans/single-inbox-identity-refactor.md`)
replaces the architecture described above. Amendments here track each checkpoint as it
lands on the `single-inbox-refactor` branch so readers of this ADR see what is still live
and what has been retired.

### C2 — Migration reset (landing now)

The GRDB migration chain was collapsed to a single baseline named `v0-single-inbox`. The
refactor explicitly ships without a data migration path: on first launch of any install
carrying pre-refactor artefacts, `LegacyDataWipe` deletes the shared GRDB file and every
`xmtp-{env}-*.db3` under the app-group container so the baseline migration runs against a
clean directory. A `convos.schemaGeneration` marker in the app-group UserDefaults records
that the wipe has run, so it only happens once per install generation.

Two new tables land with the baseline to carry the global-profile model:

- `myProfile` — singleton row for the local user's global profile (fully populated by C8).
- `profileBroadcastQueue` — pending broadcasts to per-conversation `ProfileUpdate`
  messages (drained by the worker introduced in C8).

Column removals for `inboxId`/`clientId` on `conversation`, `message`, `conversation_members`,
etc. are deferred to C4, which deletes the multi-inbox Swift layer that still references
them. The baseline migration keeps those columns in place so the current Swift code
continues to compile and run while the refactor is mid-flight.

### C3 — Keychain singleton + iCloud Keychain sync (landing now)

`KeychainIdentityStore` gains a singleton API (`saveSingleton` / `loadSingleton` /
`deleteSingleton`) that reads and writes a single identity under a fixed account key
(`single-inbox-identity`). The service name bumps from
`org.convos.ios.KeychainIdentityStore.v2` to `v3` so the new schema does not collide with
legacy entries.

**Access attributes** change to support iCloud Keychain sync:

- `kSecAttrAccessible` is relaxed from `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  to `kSecAttrAccessibleAfterFirstUnlock`. The `ThisDeviceOnly` variant is incompatible
  with Synchronizable items.
- `kSecAttrSynchronizable` is set to `true`. The user's identity now follows them across
  their Apple ID devices via iCloud Keychain.
- The former `SecAccessControlCreateWithFlags(...)` wrapper is removed. With
  Synchronizable items, access control flags are set via `kSecAttrAccessible` alone.

The app-group access group (shared with the Notification Service Extension) is
preserved. The NSE continues to read identity material from the shared keychain; nothing
else gains access.

**Known tradeoffs**, consciously accepted and reflected in the plan's "Privacy properties
we lose":

- Keys can now leave the device via iCloud Keychain sync. This is a weakening of the
  device-binding guarantee stated above ("Keys never migrate to other devices via iCloud
  Keychain"). The user's threat model has shifted toward typical consumer-app expectations
  where a lost device can be recovered via iCloud restore.
- Any attacker who compromises the user's iCloud account can obtain the identity. This
  is no worse than what Keychain Access Groups already expose to the user's trust
  boundary when signed in on multiple devices.

**Private polymorphism dropped.** The old `identity(forClientId:)` lookup (used internally
for uniqueness enforcement on save and for `delete(clientId:)`) is removed. The write path
no longer verifies clientId uniqueness — with the singleton model the question is moot —
and `delete(clientId:)` falls back to scanning `loadAll()` until the legacy multi-identity
callers are retired in C4.

**Legacy keychain cleanup.** `LegacyDataWipe` (introduced in C2) now also deletes
`KeychainIdentityStore.v1` and `v2` entries in the shared access group during the
one-shot upgrade wipe, alongside the GRDB and XMTP database files. The new `v3` store
never reads these, but without explicit cleanup they would linger indefinitely.

The multi-identity public API (`save(inboxId:clientId:keys:)`, `identity(for inboxId:)`,
`loadAll`, `delete(inboxId:)`, `delete(clientId:)`, `deleteAll`) remains available in C3
so the multi-inbox Swift stack still compiles during the intermediate state. Those
methods are retired in C4 when their callers are deleted.

### C6 — XMTP device sync enabled

`SessionStateMachine.clientOptions(keys:)` now constructs `ClientOptions` with
`deviceSyncEnabled: true` (was `false` under the per-conversation model). All other
knobs — codec registration, db encryption key, db directory, pool sizes — are unchanged.

The XMTPiOS SDK's `useDefaultHistorySyncUrl: true` (its default) resolves
`historySyncUrl` from the API environment:

- `.production` → `https://message-history.production.ephemera.network`
- `.dev`        → `https://message-history.dev.ephemera.network`
- `.local`      → `http://localhost:5558` (overridable via
  `XMTPEnvironment.customHistorySyncUrl` or the `XMTP_HISTORY_SERVER_ADDRESS`
  environment variable — used by the local Docker node in `./dev/up`)

**What device sync does here.** With one XMTP inbox per user and identity keys
now synced via iCloud Keychain (C3), enabling device sync closes the loop: when
the user adds a second device under the same Apple ID, that device's XMTP
installation — keyed off the iCloud-synced identity — can replay group
memberships and message history from the XMTP history server. The user lands on
their second device already in the same conversations without a fresh invite
exchange.

**What device sync does not give us.** History replay is scoped to group
membership, conversation metadata, and the MLS commit history that the protocol
records; application-level state that lives only in our GRDB database
(Quickname, per-conversation display preferences, unread flags) does not sync
through the XMTP history server and is deliberately out of scope for this
refactor. Multi-device UX improvements beyond "conversations show up" are
deferred; the single-inbox plan's "Non-Goals" explicitly lists pairing screens,
recovery phrases, and installation management as later work.

**Per-conversation model's rationale is inverted.** Section 4 above stated
"Device Sync Disabled: Each conversation is independent, no cross-device sync
needed." With one inbox per user that reasoning no longer applies — disabling
device sync would now leave the user's second device with an empty
conversation list despite the keychain having brought their identity over.

The codec list registered on the client in C6 matches the one present before
the refactor started: `TextCodec`, `ReplyCodec`, `ReactionV2Codec`,
`ReactionCodec`, `AttachmentCodec`, `RemoteAttachmentCodec`,
`GroupUpdatedCodec`, `ExplodeSettingsCodec`, `InviteJoinErrorCodec`,
`ProfileUpdateCodec`, `ProfileSnapshotCodec`, `JoinRequestCodec`,
`AssistantJoinRequestCodec`, `TypingIndicatorCodec`, `ReadReceiptCodec`. The
plan called for "register custom codecs on the single client" as a safety check
because the multi-inbox era had several XMTP-client construction sites; after
C4a all paths funnel through `SessionStateMachine.clientOptions`, so the full
codec list is now registered on every client the app creates.

### C7 — Single-inbox push notification routing

The **wire protocol for push notifications is unchanged**. The backend still
routes to a `clientId` (the random per-user UUID from Section 3 above),
ciphertext still never leaves XMTP, and the Notification Service Extension
still receives the same v2 payload shape. What changed is the NSE-side
routing: it no longer looks the destination up in a local `InboxesRepository`
keyed by `clientId` because the local model has collapsed to a singleton.

`CachedPushNotificationHandler` (`ConvosCore/Sources/ConvosCore/Inboxes/CachedPushNotificationHandler.swift`)
is rewritten for single-inbox:

- The cache is now a single `MessagingService?` with an access timestamp,
  replacing the old `[inboxId: MessagingService]` LRU-style map. The old
  `cleanupStaleServices` loop and `maxServiceAge: 15min` TTL collapsed to a
  single `cleanupIfStale()` check at the top of each delivery.
- On every delivery the handler reads the singleton identity from the shared
  app-group keychain via `identityStore.loadSingleton()`. If the singleton
  is absent the handler returns `nil` (suppress the notification) and best-
  effort calls `apiClient.unregisterInstallation(clientId:)` with the
  payload's JWT so the backend stops routing to a clientId whose local
  identity has been wiped.
- The payload's `clientId` is compared against the singleton's `clientId`.
  A mismatch means the payload predates the current install (e.g. user
  deleted their identity between send and deliver, or keychain state rolled
  over during a reset). Same disposition as above: suppress + unregister.
- When the payload matches, the handler lazily constructs the singleton
  `MessagingService` via `MessagingService.authorizedMessagingService(...)`
  with `startsStreamingServices: false` (NSE can't hold streams), caches it
  for reuse within the 15-minute stale window, and delegates to
  `service.processPushNotification(payload:)` exactly as before.

**Privacy properties preserved.** The backend still only ever sees the
random `clientId`. The `inboxId` still never leaves the device. The `apiJWT`
on the payload still scopes backend authority to the current installation.
The NSE still cannot read messages it was not routed to — the MLS key
material lives on one identity in the keychain.

**Privacy properties confirmed lost (already documented in C3 amendment).**
The `clientId` is now 1:1 with the user across all conversations rather than
1:1 with a single conversation, which is the per-conversation-isolation
property we traded away for the simpler architecture. Nothing in C7 changes
this tradeoff — it just simplifies the routing code that already assumed it.

Ancillary cleanup: the handler's cross-module dependency on
`InboxesRepository` is removed (no longer needed for lookup), which frees
`InboxesRepository`, `InboxWriter`, and the `inbox` table to be considered
for removal alongside the `inboxId`/`clientId` column drops in C11.

### C12 — App Clip identity bootstrap

The App Clip and the main app share a single identity slot in the keychain.
Both `Convos.entitlements` and `ConvosAppClip.entitlements` declare the same
`keychain-access-groups` array (`$(AppIdentifierPrefix)$(APP_GROUP_IDENTIFIER)`
and `$(AppIdentifierPrefix)$(KEYCHAIN_GROUP_IDENTIFIER)`), and both bind
`KeychainIdentityStore` to `AppEnvironment.keychainAccessGroup`. On the
clip's first launch `ConvosClient.client(...)` instantiates the
`KeychainIdentityStore` against the app-group access group; the first
`SessionManager.messagingService()` call triggers `makeService`, which
registers the singleton identity and writes it into that shared slot.

When the user later installs the full app, the main target's first launch
reads the same access group, `identityStore.load()` returns the clip's
identity, and `makeService` takes the `authorize` branch instead of
`register` — reusing the inboxId, clientId, and key material the clip
created. No onboarding carousel, no second registration, no keychain
overwrite.

Two unit suites pin the contract: `KeychainIdentityStoreRealKeychainTests`
round-trips a real keychain item through the shared access group, and
`AppClipIdentityHandoffTests` (in `ConvosCoreTests`) exercises the
"clip-write → main-app-load" sequence against the in-memory mock.
End-to-end coverage of the simulator-installable piece lives in
`qa/tests/37-app-clip-handoff.md`; the TestFlight-only pieces of the
real clip-invocation flow are documented there as manual steps.
