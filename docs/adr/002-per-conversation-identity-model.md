# ADR 002: Per-Conversation Identity Model with Privacy-Preserving Push Notifications

## Status

Accepted

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
- ADR 005: Profile Storage in Conversation Metadata (explains how per-conversation identities enable per-conversation profiles)

## References

- XMTP Protocol: https://xmtp.org
- iOS Keychain Services: https://developer.apple.com/documentation/security/keychain_services
- secp256k1 Elliptic Curve: https://www.secg.org/sec2-v2.pdf
- Swift Concurrency (Actors): https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
