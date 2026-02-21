# Feature: Show Pending Invites in Home View

> **Status**: Ready for Implementation
> **Author**: PRD Writer Agent
> **Created**: 2026-01-19
> **Updated**: 2026-01-21

## Overview

Show conversations in the "invite accepted, waiting to join" state (pending invites) in the home view conversations list, allowing users to tap into them and see the onboarding flow while waiting for approval.

## Problem Statement

Currently, when a user accepts an invite to join a conversation, the conversation exists in the database as a draft (ID prefix `draft-%`) and is waiting for the creator to approve the join request. These conversations are filtered out from the home view, making it unclear to users that their invite acceptance is pending. Users have no way to check the status or navigate back to a pending conversation.

The `ConversationOnboardingCoordinator.isWaitingForInviteAcceptance` flag and `InviteAcceptedView` already exist to show a status message inside the conversation, but users cannot see or access these conversations from the home screen.

## Goals

- [ ] Display pending invite conversations in the home view alongside regular conversations
- [ ] Show visual indication that these conversations are in a pending state
- [ ] Allow users to tap into pending conversations to see the "Invite accepted" onboarding flow
- [ ] Maintain existing behavior for conversations that have been fully joined
- [ ] Show pending conversations in chronological order with other conversations
- [ ] Add filter option to show only pending invites

## Non-Goals

- Not changing the underlying invite acceptance flow or state machine
- Not modifying how conversations transition from draft to joined state
- Not adding new API endpoints or backend changes
- Not changing notification behavior for pending invites
- Not creating a separate "Pending" tab or section (show in main list)

## User Stories

### As a user who accepted an invite, I want to see the pending conversation in my home view so that I know my request is being processed

Acceptance criteria:
- [ ] Conversations with `isDraft: true` and `hasJoined: false` appear in the home view
- [ ] Pending conversations show distinct visual styling (e.g., subtitle text, icon, or opacity)
- [ ] The conversation displays an "Invite accepted" or "Awaiting verification" status indicator
- [ ] Tapping the conversation opens the detail view with `InviteAcceptedView` visible

### As a user, I want pending invites to be clearly distinguishable from active conversations

Acceptance criteria:
- [ ] Pending conversations have a visual treatment that differentiates them (e.g., different subtitle text)
- [ ] The conversation list item shows that the conversation is pending (e.g., "Awaiting verification" instead of last message)
- [ ] Once approved and joined, the conversation automatically updates to show normal conversation UI

## Technical Design

### Architecture

This feature primarily affects:
- **ConvosCore**: `ConversationsRepository` filtering logic
- **Main App**: `ConversationsViewModel` and `ConversationsListItem` views

#### Dependencies
- `ConversationsRepository.composeAllConversations()` (line 55-63 in `ConversationsRepository.swift`)
- `Conversation.isDraft` property (already exists)
- `Conversation.hasJoined` computed property (already exists)
- `ConversationOnboardingCoordinator.isWaitingForInviteAcceptance` flag (already exists)

#### Key Components to Modify

**ConvosCore:**
1. `ConversationsRepository` - Remove or modify the draft filter
2. Potentially add a new computed property to `Conversation` like `isPendingInvite` for clarity

**Main App:**
1. `ConversationsViewModel` - May need additional filtering or sorting logic
2. `ConversationsListItem` - Update to show pending state
3. `ConversationViewModel` - Ensure it properly handles pending conversations
4. `NewConversationView` - Remove the "This convo will appear on your home screen after someone approves you" confirmation dialog (lines 55-67) since pending invites now appear immediately on the home screen

### Data Model

No new database fields needed. Existing fields are sufficient:
- `Conversation.isDraft: Bool` - Indicates draft/placeholder state
- `Conversation.hasJoined: Bool` - Computed from members list
- `Conversation.invite: Invite?` - Contains invite metadata

A new computed property may be helpful:

```swift
public extension Conversation {
    var isPendingInvite: Bool {
        isDraft && !hasJoined && invite != nil
    }
}
```

### Current Filtering Logic

**Current behavior in `ConversationsRepository.swift` (line 57):**
```swift
.filter(!DBConversation.Columns.id.like("draft-%"))
```

This filters out ALL draft conversations, including pending invites.

**Proposed change:**
- Remove or modify this filter to allow pending invites through
- May need to distinguish between:
  - Pending invites: `isDraft: true`, `hasJoined: false`, `invite != nil`
  - True drafts (user creating new conversation): `isDraft: true`, `invite == nil`

### UI/UX

#### Screens Affected
- `ConversationsView` (home view)
- `ConversationsListItem` (individual conversation row)
- `ConversationView` (conversation detail - already shows `InviteAcceptedView` when pending)

#### Visual Treatment

**Decision: Subtitle shows "Awaiting verification"**

```
ConversationsListItem should show:
- Title: Conversation name
- Subtitle: "Awaiting verification" (instead of last message)
- Avatar: Normal avatar
- Badge: No unread badge (empty conversation)
```

#### Navigation Flow
1. User accepts invite via QR code or link
2. `ConversationStateMachine` creates placeholder conversation (`isDraft: true`)
3. Conversation appears in home view with pending indicator
4. User taps pending conversation from home view
5. Opens `ConversationView` (`Convos/Conversation Detail/ConversationView.swift`) - same view as regular conversations
6. `ConversationOnboardingView` displays `InviteAcceptedView` showing "Invite accepted" message
7. When approved, conversation updates to `isDraft: false`, `hasJoined: true`
8. Conversation list item and detail view update to show normal state

**Important**: Pending invites use the same `ConversationView` as regular conversations - no separate view is needed. The onboarding coordinator handles showing the appropriate UI state.

### Edge Cases to Consider

1. **Multiple pending invites**: User could have several pending invites - they sort by their timestamp like other conversations (so recent ones may naturally appear at top)
2. **Expired invites**: What if the invite expires before approval? (Already handled by `expiresAt` filter)
3. **Denied invites**: If the creator denies, conversation should be removed (existing behavior)
4. **App backgrounding**: Ensure real-time updates work when conversation is approved while app is backgrounded

## Implementation Plan

### Phase 1: Core Filtering Logic
- [ ] Add `isPendingInvite` computed property to `Conversation` model
- [ ] Modify `ConversationsRepository.composeAllConversations()` to include pending invites
- [ ] Ensure filtering logic distinguishes between pending invites and true drafts
- [ ] Add unit tests for repository filtering logic

### Phase 2: UI Updates
- [ ] Update `ConversationsListItem` to detect and display pending state
- [ ] Add visual treatment (subtitle text showing "Awaiting verification")
- [ ] Ensure `ConversationViewModel` properly handles pending conversations
- [ ] Disable mute action for pending conversations (requires real conversation ID)
- [ ] Remove outdated "This convo will appear on your home screen after someone approves you" modal from `NewConversationView.swift` (lines 55-67) - no longer needed since pending invites now appear immediately
- [ ] Update SwiftUI previews for pending state

### Phase 3: Filter Toggle
- [ ] Add filter option to `ConversationsView` for pending invites
- [ ] Update `ConversationsViewModel` to support filtering by pending state
- [ ] Ensure filter persists appropriately (or resets on view load)

### Phase 4: Polish & Edge Cases
- [ ] Test transition from pending to joined state
- [ ] Verify onboarding coordinator interaction
- [ ] Test filter toggle behavior with empty states
- [ ] Add manual test scenarios for QA

## Testing Strategy

### Unit Tests
- `ConversationsRepository`: Verify draft filtering includes pending invites
- `Conversation` model: Test `isPendingInvite` computed property
- `ConversationsViewModel`: Ensure pending conversations are included in list

### Integration Tests
- Create a pending invite and verify it appears in home view
- Accept an invite and verify conversation transitions from pending to joined
- Test real-time updates when invite is approved

### Manual Testing Scenarios
1. Accept an invite via QR code, verify it appears in home view
2. Accept invite via link, verify it appears in home view
3. Tap pending conversation, verify `InviteAcceptedView` is shown
4. Wait for approval (or simulate), verify conversation updates to normal state
5. Test with multiple pending invites
6. Test expired invite behavior
7. Test app backgrounding/foregrounding during pending state
8. Verify pending invites sort chronologically by timestamp
9. Verify mute action is disabled for pending conversations
10. Test filter toggle to show only pending invites
11. Test filter toggle with zero pending invites (empty state)

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Users confused by pending conversations | Medium | Clear visual treatment and status text |
| Performance impact from including drafts | Low | Drafts are minimal in number, negligible impact |
| Filtering logic breaks other draft use cases | High | Thorough testing of draft conversation creation flow |
| Real-time updates don't trigger UI refresh | Medium | Verify ValueObservation updates propagate correctly |

## Decisions

- [x] **Sort order**: Chronological by timestamp with other conversations (recent invites may naturally appear at top)
- [x] **Count badge**: No count badge for pending invites (empty conversation)
- [x] **Pinning/read/unread**: Allow same actions as regular conversations for consistency
- [x] **Muting**: Disable mute action for pending invites (requires real conversation ID which doesn't exist yet)
- [x] **Filter toggle**: Yes, add ability to filter for pending invites
- [x] **Sending messages**: Already handled by state machine (blocked while pending)
- [x] **Subtitle text**: "Awaiting verification"

## References

- Existing code: `ConversationStateMachine.swift` (invite join flow)
- Existing code: `InviteAcceptedView.swift` (pending UI component)
- Existing code: `ConversationOnboardingCoordinator.swift` (onboarding state management)
- Related: `PendingInviteRepository.swift` (tracks pending invites per inbox)
