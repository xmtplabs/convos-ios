# Technical Design: Invite Join Error Feedback

> **Status**: Draft
> **Author**: swift-architect
> **Created**: 2026-01-07
> **Related PRD**: `docs/plans/invite-join-error-feedback.md`

## Summary

This feature introduces a custom XMTP content type (`InviteJoinError`) to communicate join request failures from the creator's client to the joiner's client via the existing DM channel. The design follows the established `ExplodeSettingsCodec` pattern and integrates with the existing `InviteJoinRequestsManager`, `StreamProcessor`, and `ConversationStateMachine` components.

---

## 1. Custom Content Type Structure

### 1.1 Data Model: `InviteJoinError`

**Location:** `ConvosCore/Sources/ConvosCore/Custom Content Types/InviteJoinErrorCodec.swift`

**Structure:**
```
InviteJoinError
├── errorType: InviteJoinErrorType (enum)
├── inviteTag: String (correlates with SignedInvite.invitePayload.tag)
└── timestamp: Date (when error occurred)
```

**Error Types Enum:**
```
InviteJoinErrorType
├── conversationExpired (rawValue: "conversation_expired")
├── genericFailure (rawValue: "generic_failure")
├── singleUseConsumed (rawValue: "single_use_consumed") [future]
└── unknown(String) [forward compatibility fallback]
```

**Design Decisions:**
- Use `String` raw values for the enum to ensure forward compatibility - unknown error types from newer clients can be parsed as `.unknown(rawValue)` and treated as generic failure
- Include `inviteTag` to correlate errors with specific join attempts (matches `SignedInvite.invitePayload.tag`)
- Include `timestamp` for debugging and potential future retry logic

### 1.2 Codec: `InviteJoinErrorCodec`

**Pattern:** Follow `ExplodeSettingsCodec` exactly (see `ConvosCore/Sources/ConvosCore/Custom Content Types/ExplodeSettingsCodec.swift`)

**Content Type ID:**
```
authorityID: "convos.org"
typeID: "invite_join_error"
versionMajor: 1
versionMinor: 0
```

**Key Implementation Details:**
- Implements `ContentCodec` protocol from XMTPiOS
- Uses JSON encoding with ISO8601 date strategy (same as ExplodeSettingsCodec)
- `shouldPush(content:)` returns `true` to ensure offline delivery
- `fallback(content:)` returns user-friendly error message string

**Error Handling:**
```
InviteJoinErrorCodecError
├── emptyContent
└── invalidJSONFormat
```

---

## 2. Sender Side (Creator)

### 2.1 Error Detection in `InviteJoinRequestsManager`

**File:** `ConvosCore/Sources/ConvosCore/Syncing/InviteJoinRequestsManager.swift`

**Current Behavior (lines 89-110):** The `processJoinRequestSafely` method catches errors and logs them but does not notify the joiner.

**Modification Points:**

1. **Add DM reference to error handling:** Pass the DM conversation to error handlers so error messages can be sent back via the same channel.

2. **Map `InviteJoinRequestError` to `InviteJoinErrorType`:**

| InviteJoinRequestError | InviteJoinErrorType |
|------------------------|---------------------|
| `.expiredConversation` | `.conversationExpired` |
| `.conversationNotFound(id)` | `.conversationExpired` |
| All other errors | `.genericFailure` |

3. **Extract invite tag for correlation:** The `signedInvite.invitePayload.tag` is available at line 138 after parsing - capture this before error handling.

### 2.2 New Helper Method: `sendJoinError`

**Location:** Add to `InviteJoinRequestsManager` (or extract to separate `InviteJoinErrorSender` class for testability)

**Dependencies:**
- `XMTPiOS.Dm` - the DM conversation to send via
- `InviteJoinError` - the error payload
- `AnyClientProvider` - for sending messages

**Protocol Extension Approach:**

Extend `MessageSender` protocol (in `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift`) with:
```swift
func sendInviteJoinError(_ error: InviteJoinError) async throws
```

And add extension on `XMTPiOS.Conversation` (similar to `sendExplode` at line 217) that:
1. Creates `InviteJoinErrorCodec`
2. Calls `send(content:options:)` with the codec's content type

**Error Handling for Sending:**
- Log failures but do not throw - error sending should not block other operations
- Fire-and-forget pattern (joiner already cannot join, sending failure is non-critical)

### 2.3 Integration Flow

```
processJoinRequest called
    ├── Parse signedInvite (line 138)
    │   └── Capture inviteTag = signedInvite.invitePayload.tag
    ├── Error occurs
    │   ├── Determine errorType from InviteJoinRequestError
    │   ├── Create InviteJoinError(errorType, inviteTag, Date())
    │   └── Call sendJoinError on DM conversation
    └── Continue with existing error logging
```

---

## 3. Receiver Side (Joiner)

### 3.1 Message Detection in `StreamProcessor`

**File:** `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`

**Current Behavior (lines 128-195):** The `processMessage` method routes messages to either `joinRequestsManager.processJoinRequest()` for DMs or message storage for groups.

**Modification:**

Add error message detection in the DM handling branch (lines 143-152):

```swift
case .dm:
    // Check for InviteJoinError first
    if let inviteJoinError = decodeInviteJoinError(from: message) {
        await handleInviteJoinError(inviteJoinError, senderInboxId: message.senderInboxId)
        return
    }
    // Existing join request processing
    do { ... }
```

**New Method: `decodeInviteJoinError`**

Pattern matches `decodeExplodeSettings` in `IncomingMessageWriter`:
- Check if `message.encodedContent.type == ContentTypeInviteJoinError`
- Decode using `InviteJoinErrorCodec`
- Return `InviteJoinError?`

### 3.2 Error Routing to StateMachine

**Challenge:** `StreamProcessor` does not currently have a reference to `ConversationStateMachine`.

**Solution Options:**

**Option A: NotificationCenter**
- Post `Notification.Name.inviteJoinError` with `userInfo` containing `inviteTag` and `errorType`
- `ConversationStateMachine` observes this notification and matches by `inviteTag`
- Pros: Loose coupling, follows existing pattern (see `.conversationExpired` notification at line 147 in IncomingMessageWriter)
- Cons: Indirect communication, harder to test

**Option B (Recommended): Protocol Injection**
- Create `InviteJoinErrorHandler` protocol
- Inject handler into `StreamProcessor`
- Pros: Explicit dependency, testable, type-safe
- Cons: Requires modification to `StreamProcessor` initialization chain

**Option C: Database-based**
- Write error to database (new table or column on DBConversation)
- `ConversationStateMachine` observes via `ValueObservation`
- Pros: Persistence for offline scenarios
- Cons: More complex, requires schema changes

**Recommendation:** Option B (Protocol Injection) for explicit dependencies and better testability.

### 3.3 Protocol Definition

**New Protocol: `InviteJoinErrorHandler`**

**Location:** `ConvosCore/Sources/ConvosCore/Inboxes/InviteJoinErrorHandler.swift` (new file)

```swift
protocol InviteJoinErrorHandler {
    func handleInviteJoinError(_ error: InviteJoinError) async
}
```

**Implementation by `ConversationStateMachine`:**

The state machine conforms to this protocol and implements error handling based on current state.

### 3.4 StreamProcessor Integration

**Modification:** Add `InviteJoinErrorHandler` property to `StreamProcessor`

```swift
// In StreamProcessor initialization
init(
    // ... existing parameters
    inviteJoinErrorHandler: InviteJoinErrorHandler? = nil
) {
    // ... store handler
}
```

**Error Routing:**

In `handleInviteJoinError` (called from processMessage when error detected):
```swift
private func handleInviteJoinError(_ error: InviteJoinError, senderInboxId: String) async {
    await inviteJoinErrorHandler?.handleInviteJoinError(error)
}
```

### 3.5 State Machine Handling

**File:** `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`

**New State:**
```swift
case joinFailed(inviteTag: String, error: InviteJoinError)
```

Add to `State` enum (line 40) after `.joining`.

**Protocol Conformance:**
```swift
extension ConversationStateMachine: InviteJoinErrorHandler {
    func handleInviteJoinError(_ error: InviteJoinError) async {
        // Only handle if we're currently joining with matching inviteTag
        guard case .joining(let invite, _) = _state,
              error.inviteTag == invite.invitePayload.tag else {
            return
        }

        // Cancel observation task
        observationTask?.cancel()
        observationTask = nil

        // Transition to joinFailed state
        emitStateChange(.joinFailed(inviteTag: error.inviteTag, error: error))
    }
}
```

**Equatable Implementation:**
```swift
case let (.joinFailed(lhsTag, _), .joinFailed(rhsTag, _)):
    return lhsTag == rhsTag
```

---

## 4. ViewModel Integration

### 4.1 State Manager Updates

**File:** `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationStateManager.swift`

**Add to `handleStateChange` (line 176):**
```swift
case .joinFailed(_, let error):
    isReady = false
    hasError = true
    errorMessage = error.userFacingMessage
```

**Add computed property to `InviteJoinError`:**
```swift
var userFacingMessage: String {
    switch errorType {
    case .conversationExpired:
        return "This conversation is no longer available"
    case .singleUseConsumed:
        return "This invite was already used by someone else"
    case .genericFailure, .unknown:
        return "Failed to join conversation"
    }
}
```

### 4.2 NewConversationViewModel Updates

**File:** `Convos/Conversation Creation/NewConversationViewModel.swift`

**Add case to `handleStateChange` (line 227):**
```swift
case .joinFailed(_, let error):
    conversationViewModel.isWaitingForInviteAcceptance = false
    isCreatingConversation = false
    currentError = InviteJoinFailedError(error)
    // Show error UI
    handleError(InviteJoinFailedError(error))
```

**New Error Type:**
```swift
struct InviteJoinFailedError: DisplayError {
    let joinError: InviteJoinError

    var title: String {
        switch joinError.errorType {
        case .conversationExpired:
            return "Convo no longer exists"
        case .singleUseConsumed:
            return "Invite already used"
        case .genericFailure, .unknown:
            return "Couldn't join"
        }
    }

    var description: String {
        joinError.userFacingMessage
    }
}
```

---

## 5. Edge Cases

### 5.1 Manual Cancellation Race Conditions

**Scenario:** User cancels join (calls `stop()`), but error message arrives afterward.

**Solution:** The protocol handler implementation in `ConversationStateMachine` checks current state before transitioning:
```swift
guard case .joining(let invite, _) = _state,
      error.inviteTag == invite.invitePayload.tag else {
    // Ignore error for non-matching or already-cancelled join
    return
}
```

If the user has cancelled, the state machine is no longer in `.joining` state, so the error is safely ignored.

### 5.2 Error Message Persistence (Optional Enhancement)

**Scenario:** Error sent while joiner offline, push notification missed.

**Current Design:** Push notification ensures delivery (`shouldPush: true`). XMTP stream will deliver the message when client reconnects.

**Optional Enhancement:** When entering `.joining` state and an existing DM with the inviter exists, fetch the last message to check if an error was already sent:
```swift
// In handleJoin, before waiting for conversation
if let lastMessage = try? await dm.lastMessage(),
   let error = decodeInviteJoinError(from: lastMessage) {
    // Error was already sent while we were offline
    emitStateChange(.joinFailed(inviteTag: invite.invitePayload.tag, error: error))
    return
}
```

---

## 6. Dependencies and Module Boundaries

### 6.1 ConvosCore (New/Modified Files)

| File | Change Type | Description |
|------|-------------|-------------|
| `Custom Content Types/InviteJoinErrorCodec.swift` | **NEW** | Content type, codec, error enum |
| `Inboxes/InviteJoinErrorHandler.swift` | **NEW** | Protocol for error handling |
| `Syncing/InviteJoinRequestsManager.swift` | MODIFY | Add `sendJoinError`, integrate with error handling |
| `Syncing/StreamProcessor.swift` | MODIFY | Add `decodeInviteJoinError`, inject error handler, route errors |
| `Inboxes/ConversationStateMachine.swift` | MODIFY | Add `.joinFailed` state, implement `InviteJoinErrorHandler` |
| `Storage/Writers/ConversationStateManager.swift` | MODIFY | Handle `.joinFailed` state |
| `Messaging/XMTPClientProvider.swift` | MODIFY | Add `sendInviteJoinError` to protocol |

### 6.2 Main App (Modified Files)

| File | Change Type | Description |
|------|-------------|-------------|
| `Conversation Creation/NewConversationViewModel.swift` | MODIFY | Handle `.joinFailed` state |

### 6.3 Codec Registration

The XMTP SDK in this codebase appears to auto-register codecs. If explicit registration is needed, add to the same location where `ExplodeSettingsCodec` is registered (search for codec registration pattern in XMTP client initialization).

---

## 7. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Error message lost in transit | Medium | `shouldPush: true` ensures push notification; XMTP persistence ensures eventual delivery |
| Forward compatibility - new error types | Low | Unknown enum values fall back to `.unknown(rawValue)` treated as generic failure |
| State machine race conditions | Low | Explicit `inviteTag` matching and state checks prevent incorrect transitions |
| Breaking change to DM message handling | Medium | Error detection happens before join request processing; non-error messages flow through unchanged |

---

## 8. Testing Strategy

### Unit Tests

1. **InviteJoinErrorCodec**
   - Encode/decode round-trip
   - Forward compatibility (unknown error types)
   - Empty content handling
   - Invalid JSON handling

2. **InviteJoinRequestsManager**
   - Error detection triggers `sendJoinError`
   - Correct error type mapping
   - DM sending failures logged but not thrown

3. **StreamProcessor**
   - Error messages detected and routed
   - Non-error DM messages still processed as join requests
   - Error handler protocol called with correct error

4. **ConversationStateMachine**
   - `.joining` -> `.joinFailed` transition on matching `inviteTag`
   - Non-matching `inviteTag` ignored
   - Manual cancellation before error prevents transition
   - `InviteJoinErrorHandler` protocol implementation

### Integration Tests

1. End-to-end: Creator processes invalid join request -> Joiner receives error
2. Offline joiner: Error sent while offline, received on reconnect

---

## 9. File References

- PRD: `docs/plans/invite-join-error-feedback.md`
- ExplodeSettingsCodec Pattern: `ConvosCore/Sources/ConvosCore/Custom Content Types/ExplodeSettingsCodec.swift`
- InviteJoinErrorHandler Protocol (NEW): `ConvosCore/Sources/ConvosCore/Inboxes/InviteJoinErrorHandler.swift`
- InviteJoinRequestsManager: `ConvosCore/Sources/ConvosCore/Syncing/InviteJoinRequestsManager.swift`
- ConversationStateMachine: `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`
- StreamProcessor: `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`
- XMTPClientProvider: `ConvosCore/Sources/ConvosCore/Messaging/XMTPClientProvider.swift`
- ConversationStateManager: `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationStateManager.swift`
- NewConversationViewModel: `Convos/Conversation Creation/NewConversationViewModel.swift`
- SignedInvite Accessors: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Accessors.swift`
