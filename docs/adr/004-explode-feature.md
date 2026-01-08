# ADR 004: Conversation Explode Feature

## Status

Accepted

## Context

Convos is designed for ephemeral, privacy-focused messaging. Users need the ability to permanently destroy conversations, removing all traces from their device and notifying all participants to do the same. This "explode" feature must:

- Irreversibly delete all conversation data (messages, members, metadata)
- Delete the XMTP private keys for the conversation's identity (per ADR 002)
- Delete the local XMTP database
- Notify all participants to delete their copies
- Work reliably even when participants are offline
- Prevent conversation re-sync after deletion

Traditional messaging apps rely on centralized servers to enforce deletion, but Convos uses XMTP's decentralized infrastructure. We need a solution that propagates deletion requests peer-to-peer while respecting the trust model constraints of a decentralized system.

## Decision

We implemented a **message-based explosion system** using a custom XMTP content type to propagate deletion requests across all conversation participants. The per-conversation identity model (ADR 002) ensures that deleting the conversation's inbox completely destroys the cryptographic identity associated with that conversation.

### 1. Custom Content Type: ExplodeSettings

We defined a custom XMTP content type to signal conversation explosion to all members.

**Content Type Definition:**

```swift
public struct ExplodeSettings: Codable {
    public let expiresAt: Date
}

public let ContentTypeExplodeSettings = ContentTypeID(
    authorityID: "convos.org",
    typeID: "explode_settings",
    versionMajor: 1,
    versionMinor: 0
)
```

**Protocol Details:**

- **Authority ID**: `convos.org` - Custom namespace for Convos-specific content types
- **Type ID**: `explode_settings` - Identifies this as an explosion notification
- **Version**: 1.0
- **Payload**: JSON-encoded `ExplodeSettings` with ISO8601 date
- **Fallback Text**: "Conversation expires at {date}" for non-Convos clients
- **Push Notification**: `shouldPush = true` ensures offline devices receive the message

**Codec Registration:**

The codec is registered with every XMTP client during initialization alongside standard codecs (text, reactions, attachments, etc.).

**Location:** `ConvosCore/Sources/ConvosCore/Custom Content Types/ExplodeSettingsCodec.swift`

### 2. Expiration Storage

Conversation expiration is stored in two locations:

#### 2.1 Local Database (Primary)

The `DBConversation` table includes an `expiresAt` field:

```swift
struct DBConversation {
    let id: String
    let inboxId: String
    let clientId: String
    // ...
    let expiresAt: Date?  // nil = active, non-nil = exploded
}
```

This field is:
- `nil` for active conversations
- Set to the explosion timestamp when an ExplodeSettings message is received or sent
- Queried by `ExpiredConversationsWorker` to trigger cleanup

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift`

#### 2.2 XMTP Custom Metadata (Secondary)

The expiration is also stored in the XMTP group's `appData` field as part of `ConversationCustomMetadata`:

```swift
extension XMTPiOS.Group {
    public var expiresAt: Date? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasExpiresAtUnix else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(metadata.expiresAtUnix))
        }
    }

    public func updateExpiresAt(date: Date) async throws {
        var customMetadata = try currentCustomMetadata
        customMetadata.expiresAtUnix = Int64(date.timeIntervalSince1970)
        try await updateMetadata(customMetadata)
    }
}
```

This serves as a persistent record in XMTP's MLS group state, though the primary deletion trigger is the message-based notification (not the metadata).

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`

### 3. Explosion Flow: Initiator (Creator)

When a conversation creator triggers an explosion:

**Step 1: Validation**
- Verify user has `canRemoveMembers` permission (creator only)
- Verify explosion state is `.ready` (not already exploding)

**Step 2: Send ExplodeSettings Message**
```swift
try await xmtpConversation.sendExplode(expiresAt: Date())
```

The message is sent BEFORE local cleanup to maximize the chance all members receive it.

**Step 3: Local Cleanup**
1. Update local database: `expiresAt = Date()`
2. Remove all members from XMTP group
3. Set XMTP consent state to `.denied` (prevents re-sync)
4. Post `.leftConversationNotification` (triggers inbox deletion)

**Step 4: Inbox Deletion**
The `SessionManager` observes `.leftConversationNotification` and deletes the entire inbox (see section 5).

**Location:** `Convos/Conversation Detail/ConversationViewModel.swift:512-572`

### 4. Explosion Flow: Receiver (Members)

When members receive an ExplodeSettings message:

**Step 1: Message Received**
The `StreamProcessor` receives the message via XMTP's message stream.

**Step 2: Content Type Routing**
```swift
case ContentTypeExplodeSettings:
    let settings = try ExplodeSettings(from: message)
    processExplodeSettings(settings, ...)
```

**Step 3: Validation**
- Skip if message is from self (creator already cleaned up locally)
- Skip if conversation already has `expiresAt` set (idempotency)

**Step 4: Database Update**
```swift
try await dbWriter.write { db in
    try DBConversation
        .filter(DBConversation.Columns.id == conversationId)
        .updateAll(db, DBConversation.Columns.expiresAt.set(to: settings.expiresAt))
}
```

**Step 5: Notification**
Post `.conversationExpired` notification, which triggers the `ExpiredConversationsWorker`.

**Location:** `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift:167-222`, `ConvosCore/Sources/ConvosCore/Storage/Writers/IncomingMessageWriter.swift:111-158`

### 5. Deletion Mechanism

The `ExpiredConversationsWorker` monitors for expired conversations and triggers cleanup.

**Monitoring Triggers:**
- App becomes active (foreground)
- `.conversationExpired` notification
- `.explosionNotificationTapped` notification (user tapped push notification)

**Cleanup Process:**

**Step 1: Query Expired Conversations**
```sql
SELECT * FROM conversation
WHERE expiresAt IS NOT NULL
AND expiresAt <= :now
```

**Step 2: Post Deletion Notification**
For each expired conversation:
```swift
NotificationCenter.default.post(
    name: .leftConversationNotification,
    userInfo: ["clientId": clientId, "inboxId": inboxId]
)
```

**Step 3: Inbox Deletion**
The `SessionManager` observes the notification and triggers full inbox deletion via `InboxStateMachine.handleDelete()`:

1. **Unsubscribe from Push Topics**: Remove XMTP topic subscriptions from backend
2. **Unregister Installation**: Remove device registration for this inbox
3. **Delete Database Records**:
   - All `DBMessage` entries for conversations in this inbox
   - All `DBConversationMember` entries
   - All `ConversationLocalState` entries
   - All `DBInvite` entries (sent and received)
   - All `DBMemberProfile` entries
   - The `DBMember` record for this inbox
   - All `DBConversation` entries for this inbox
   - The `DBInbox` record
4. **Delete Keychain Identity**: Remove the XMTP private keys from iOS Keychain (see ADR 002)
5. **Delete XMTP Database**: Remove local XMTP database files (`xmtp-{env}-{inboxId}.db3` and associated files)

**Important**: The per-conversation identity model (ADR 002) means each conversation has its own private key. Deleting the inbox destroys the cryptographic identity for that conversation, making recovery cryptographically impossible even if message data somehow remained.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Workers/ExpiredConversationsWorker.swift`, `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift:129-147`, `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift`

### 6. State Management

The UI tracks explosion state to provide user feedback:

```swift
enum ExplodeState: Equatable {
    case ready         // Can initiate explosion
    case exploding     // Explosion in progress
    case exploded      // Animation complete, cleanup happening
    case error(String) // Explosion failed
}
```

The explosion button uses a "hold to confirm" interaction pattern with animated visual feedback to prevent accidental explosions.

**Location:** `Convos/Conversation Detail/ExplodeButton.swift`

### 7. Scheduled Explosions (Future Feature)

**Not Yet Implemented**

The `ExplodeSettings.expiresAt` field supports future timestamps, enabling scheduled explosions. Implementation would require:

1. UI for selecting expiration time (e.g., "1 hour", "24 hours", "7 days")
2. Background monitoring to check for future-dated expirations
3. Clock synchronization handling (devices may have slightly different times)
4. Consideration for timezone differences across participants

The architecture already supports this - the receiver logic compares `expiresAt` against the current time and only triggers cleanup when the time has passed.

**Location:** `ConvosCore/Sources/ConvosCore/Storage/Writers/IncomingMessageWriter.swift` (comment indicating future feature)

## Consequences

### Positive

- **Complete Data Destruction**: Deletes messages, metadata, private keys, and local databases
- **Cryptographic Assurance**: Per-conversation private keys are destroyed, making cryptographic recovery impossible
- **Offline Support**: Push notifications ensure offline devices receive explosion requests
- **Idempotent**: Handles duplicate explosion messages gracefully
- **Re-sync Prevention**: XMTP consent state set to `.denied` prevents conversation from reappearing
- **Decentralized**: No central server required to coordinate deletion
- **Future-Ready**: Architecture supports scheduled explosions when implemented

### Negative

- **No Cryptographic Enforcement**: Cannot force malicious or modified clients to delete
- **Backup Data**: Cannot delete data in iCloud/device backups
- **Network Dependency**: If ExplodeSettings message fails to send, only initiator deletes
- **Trust Model**: Relies on cooperative clients processing explosion requests
- **Offline Delay**: Devices that are offline when explosion occurs may not delete until next app launch
- **Message Caches**: iOS may retain message content in system caches briefly after deletion

### Security Model

| Threat | Mitigation |
|--------|------------|
| Malicious client refuses to delete | None - relies on trust model |
| Data in device backups | User must disable iCloud backup for Convos |
| Message recovery from XMTP network | Consent state `.denied` prevents re-sync |
| Cryptographic recovery of messages | Private key deletion makes decryption impossible |
| Re-adding to conversation after explosion | Not possible - conversation identity destroyed |
| Offline devices miss explosion | Push notification ensures delivery when device comes online |
| Duplicate explosion messages | Idempotency check prevents double-processing |

### Trust Model

**Important Limitation**: Convos cannot cryptographically enforce deletion on remote devices. The explosion mechanism relies on:

1. **Cooperative Clients**: Clients must implement the ExplodeSettings codec correctly
2. **Push Delivery**: Offline devices must receive push notifications
3. **Unmodified Code**: Clients must not be modified to ignore explosion requests

This is inherent to the decentralized model. Users should understand that:
- A technically sophisticated adversary could modify their client to ignore explosions
- Message content may exist in device backups until those are deleted
- iOS system caches may retain data briefly

However, the per-conversation identity model provides cryptographic assurance: even if message data somehow remains, the private key required to decrypt new messages is destroyed.

### Comparison to Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **Message-based (chosen)** | Decentralized, uses existing XMTP infrastructure, offline support via push | Cannot enforce on malicious clients |
| **Server-enforced deletion** | Can enforce by blocking message access | Requires centralized server, privacy concerns, against XMTP philosophy |
| **Cryptographic time-locks** | Mathematical enforcement | Complex implementation, clock sync issues, no immediate deletion |
| **Manual per-device deletion** | Simple implementation | Poor UX, no coordination across devices |

## Related Files

**Custom Content Type:**
- `ConvosCore/Sources/ConvosCore/Custom Content Types/ExplodeSettingsCodec.swift` - XMTP content codec

**Message Processing:**
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` - Routes ExplodeSettings messages
- `ConvosCore/Sources/ConvosCore/Storage/Writers/IncomingMessageWriter.swift` - Processes ExplodeSettings

**Cleanup Orchestration:**
- `ConvosCore/Sources/ConvosCore/Storage/Workers/ExpiredConversationsWorker.swift` - Monitors expired conversations
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` - Coordinates inbox deletion
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` - Performs full cleanup

**Storage:**
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift` - Database model with expiresAt
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift` - XMTP metadata storage

**UI:**
- `Convos/Conversation Detail/ConversationViewModel.swift` - Initiates explosion
- `Convos/Conversation Detail/ExplodeButton.swift` - UI component

**XMTP Integration:**
- `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift` - `sendExplode()` extension

## Related ADRs

- ADR 002: Per-Conversation Identity Model (explains why destroying the inbox destroys the conversation's cryptographic identity)
- ADR 003: Inbox Lifecycle Management (explains inbox deletion process)
- ADR 005: Profile Storage in Conversation Metadata (also uses XMTP custom metadata for expiration timestamps)

## References

- XMTP Content Types: https://xmtp.org/docs/build/messages
- XMTP Custom Content Types: https://github.com/xmtp/xmtp-ios/blob/main/XMTP/Proto/message_contents/content.proto
- iOS Keychain Services: https://developer.apple.com/documentation/security/keychain_services
