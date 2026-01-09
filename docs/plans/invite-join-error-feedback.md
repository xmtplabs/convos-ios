# Feature: Invite Join Error Feedback

> **Status**: Draft
> **Author**: @yewreeka
> **Created**: 2026-01-07
> **Updated**: 2026-01-07
>
> **Note**: This PRD outlines the problem, goals, and high-level approach. Detailed technical design and implementation specifics should be determined by the `swift-architect` agent, which can provide architecture-specific recommendations based on existing patterns in the codebase.

## Overview

Add a feedback mechanism for invite join request failures by introducing a custom XMTP content type that allows the creator's client to communicate specific error conditions back to the joiner via DM. This prevents joiners from being stuck in a perpetual "waiting for approval" state when their join request cannot be fulfilled.

## Problem Statement

The current decentralized invite system (documented in ADR 001) lacks error feedback when join requests fail. The flow works as follows:

1. Joiner scans an invite QR code or clicks an invite link
2. Joiner's client validates the invite locally (including expiration check)
3. Joiner's client sends a join request via XMTP DM to the creator
4. Creator's client processes the request in `InviteJoinRequestsManager.swift`
5. If processing fails (e.g., single-use invite already consumed, conversation expired, or unknown error), the creator's client logs the error locally but sends nothing back
6. Joiner's client remains in "validated" or "joining" state, indefinitely waiting for a conversation that will never appear

This creates a poor UX where users don't understand why they cannot join a conversation and have no actionable information.

## Goals

- [ ] Provide clear error feedback to joiners when their join request fails
- [ ] Support error types: conversation expired, generic failure, and single-use consumed (when implemented)
- [ ] Maintain the decentralized architecture without introducing a backend dependency
- [ ] Follow existing XMTP custom content type patterns (like `ExplodeSettings`)
- [ ] Ensure error messages arrive even if the joiner is temporarily offline

**Notes**:
- Invite expiration is validated client-side before sending the join request (the expiration is part of the signed invite payload), so no server-side error is needed for expired invites
- Single-use consumed error type will be implemented when single-use invites feature is fully developed

## Non-Goals

- Not handling network-level errors (those should be handled by retry logic)
- Not adding error feedback for conversation creation failures (different flow)
- Not implementing a generic error notification system beyond join requests
- Not adding analytics or tracking of error occurrences

## User Stories

### As a joiner, I want to know immediately when my join request fails so that I understand why I cannot join

Acceptance criteria:
- [ ] When creator's client detects a join request error, it sends an error message via the same DM channel
- [ ] Joiner's client receives and processes the error message
- [ ] ViewModel exposes error state with specific error type
- [ ] Error state replaces the "waiting for approval" loading state
- [ ] User is informed to request another invite from the inviter (no retry mechanism)

### As a joiner, I want to see specific error messages so I can take appropriate action

Acceptance criteria:
- [ ] Conversation expired: "This conversation is no longer available"
- [ ] Generic failure: "Failed to join conversation"
- [ ] Single-use invite consumed (future): "This invite was already used by someone else"
- [ ] Error messages are user-friendly
- [ ] User understands they need to request another invite from the inviter

### As a creator, I want failed join requests to automatically notify the joiner without manual intervention

Acceptance criteria:
- [ ] Error messages are sent automatically when `InviteJoinRequestsManager` detects a failure
- [ ] No additional creator action required
- [ ] Error sending failures are logged but don't block other operations

### As a developer, I want to easily extend error types in the future

Acceptance criteria:
- [ ] Error type is represented as an enum that can be extended
- [ ] Codec handles unknown error types gracefully (forward compatibility)
- [ ] Adding new error types doesn't require protocol version changes

## Technical Design

> **Note**: The following represents a high-level technical approach. The `swift-architect` agent should be consulted to design the specific implementation details, following existing codebase patterns.

### Architecture Overview

This feature integrates into the existing invite system with these key changes:

**Components to Modify:**
- `InviteJoinRequestsManager.swift` (ConvosCore) - Detect errors and send error messages
- `ConversationStateMachine.swift` (ConvosCore) - Handle received error messages and transition to error state
- `StreamProcessor.swift` (ConvosCore) - Process incoming error messages from DM stream

**New Components:**
- Custom XMTP content type for invite join errors (following pattern of `ExplodeSettingsCodec`)
- Error state handling in the join flow UI

**Module Placement:**
- Core logic → ConvosCore
- Views/ViewModels → Main App

### Proposed Error Types

The error message should communicate one of these conditions:
1. **Single-use consumed**: Invite was valid but already used by someone else
2. **Conversation expired**: The conversation has been deleted/exploded (ADR 004)
3. **Generic failure**: Catch-all for validation errors or unknown issues

**Note**: Invite expiration is validated client-side before sending the join request (expiration is part of the signed invite payload), so no server-side error is needed.

### High-Level Flow

**Sender (Creator) Side:**
1. `InviteJoinRequestsManager` detects join request failure
2. Identifies error type (single-use consumed, conversation expired, etc.)
3. Sends error message via same XMTP DM channel used for join request
4. Logs error locally

**Receiver (Joiner) Side:**
1. `StreamProcessor` receives error message from DM
2. Matches error to pending join request using invite tag
3. Transitions `ConversationStateMachine` to error state
4. UI displays user-friendly error message

### Design Considerations for Architect

- Should follow the custom content type pattern used by `ExplodeSettingsCodec` (ADR 004)
- Error matching likely needs invite tag to correlate with the specific join attempt
- Consider using protocol wrappers (`XMTPClientProvider`) instead of direct XMTP SDK types
- Need to handle race conditions (error arrives after manual cancellation)
- Should include `shouldPush: true` to ensure offline joiners receive errors

**Error Message Persistence:**
Since errors are sent as XMTP DM messages, they persist in the message stream and will be delivered through the stream when the client reconnects (even if the push notification was missed). Consider implementing a check that fetches the last message from the DM using the XMTP SDK to see if an error was sent while in the "joining" state. This provides a reliable way to detect errors that may have been sent during offline periods or missed somehow.

### UI/UX

Screens affected:
- **Join Flow Screen** (main app): Currently shows "Waiting for approval" loading state

New states needed:
- Error state when join fails
- User will be prompted to request another invite from the inviter (no retry mechanism)

**UI Implementation:**
- UI work will be done manually (not part of this PRD implementation)
- ViewModel should expose the error state and error type
- Specific UI design for error state is TBD
- Error messages should communicate:
  - Conversation expired: "This conversation is no longer available"
  - Generic failure: "Failed to join conversation"
  - Single-use consumed (future): "This invite was already used by someone else"

Navigation flow:
1. User enters invite code
2. State machine transitions to `.validated` → `.joining`
3. If error message received, transition to `.joinFailed(error)`
4. ViewModel exposes error details
5. View layer will handle error display (design TBD)

## Implementation Plan

### Phase 1: Core Infrastructure
- [ ] Create `InviteJoinErrorCodec.swift` with content type definition
- [ ] Register codec in XMTP client initialization
- [ ] Add unit tests for codec encode/decode

### Phase 2: Error Detection and Sending
- [ ] Update `InviteJoinRequestsManager.processJoinRequest` to detect error conditions
- [ ] Implement `sendJoinError` helper method
- [ ] Add error sending for conversation expired and generic failure error types
- [ ] Add unit tests for error detection logic
- [ ] Note: Single-use consumed error type will be implemented when single-use invites feature is developed

### Phase 3: Error Reception and State Management
- [ ] Add `.joinFailed` state to `ConversationStateMachine.State`
- [ ] Update `StreamProcessor` to detect and route `InviteJoinError` messages
- [ ] Add state machine logic to transition to error state
- [ ] Add integration tests for error flow

### Phase 4: ViewModel Integration
- [ ] Update ViewModel to expose error state and error type
- [ ] Ensure error details are accessible for UI layer
- [ ] Note: UI implementation will be done manually outside this plan

### Phase 5: Documentation
- [ ] Update documentation (ADRs, CLAUDE.md if needed)

## Testing Strategy

- Unit tests for:
  - `InviteJoinErrorCodec` encode/decode
  - Error type matching and forward compatibility
  - `InviteJoinRequestsManager` error detection
  - State machine state transitions
  - ViewModel error state exposure

- Integration tests for:
  - End-to-end error flow (creator detects error → joiner receives message)
  - Error delivery through XMTP message stream
  - Multiple error types in sequence

- Manual testing:
  - Explode a conversation, then have someone try to join via old invite (conversation expired error)
  - Simulate generic failure (e.g., malformed join request), verify error reaches ViewModel
  - Test with poor network conditions
  - Test across different app versions (forward compatibility)
  - Test manual cancellation: cancel join attempt, verify arriving error is dropped
  - Single-use invite testing will be added when that feature is implemented
  - Note: UI-level testing will be done manually as part of separate UI work

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Error message lost due to network issues | Medium | Mark as `shouldPush: true` to ensure delivery even if offline; log sending failures |
| Joiner already deleted DM before error arrives | Low | Error fails silently; joiner already gave up anyway |
| Joiner manually cancelled before error arrives | Low | Push notification is received but dropped/not displayed; no user impact |
| Forward compatibility when adding new error types | Low | Use enum with rawValue fallback; unknown types treated as generic failure |
| Race condition: error arrives before join request processed | Low | Match error to invite tag; ignore errors for invites not in "joining" state |

## Open Questions

- [ ] Single-use invite consumption tracking: How should we track when a single-use invite has been consumed? (Note: Single-use invites are a future feature not yet fully implemented, so this design decision will be made when that feature is developed)

## References

- ADR 001: Decentralized Invite System (`docs/adr/001-invite-system-architecture.md`)
- ExplodeSettings Codec: `ConvosCore/Sources/ConvosCore/Custom Content Types/ExplodeSettingsCodec.swift`
- InviteJoinRequestsManager: `ConvosCore/Sources/ConvosCore/Syncing/InviteJoinRequestsManager.swift`
- ConversationStateMachine: `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift`
