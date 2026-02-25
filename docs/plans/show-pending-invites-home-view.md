# Feature: Show Pending Invites in Home View

> **Status**: Ready for Implementation
> **Author**: PRD Writer Agent
> **Created**: 2026-01-19
> **Updated**: 2026-02-23

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
- `ConversationsRepository.composeAllConversations()` — the private GRDB extension on `Database` (in `ConversationsRepository.swift`)
- `Conversation.isDraft` property (already exists — derived from `DBConversation.isDraft` which checks `draft-` prefix on both `id` and `clientConversationId`)
- `Conversation.hasJoined` computed property (already exists — checks `members.contains(where: { $0.isCurrentUser })`)
- `ConversationOnboardingCoordinator.isWaitingForInviteAcceptance` flag (already exists)
- `DBConversation.Columns.isUnused` — added in the "Pre-create conversations" PR (#382). Must **not** be confused with pending invites (unused conversations are pre-created but never shown to the user; pending invites are user-initiated joins awaiting approval).

#### Key Components to Modify

**ConvosCore:**
1. `ConversationsRepository` — Modify the `composeAllConversations` GRDB query to include pending invites (currently filters out all `draft-%` conversations)
2. Add a `isPendingInvite` computed property to `Conversation` for clarity
3. Coordinate with `PendingInviteRepository` — this repo already tracks pending invites per inbox and has `PendingInviteDetail` with member count, invite tag, etc. We may be able to reuse some of its query logic.

**Main App:**
1. `ConversationsViewModel` — Add a `.pendingInvites` case to `ConversationFilter` (alongside existing `.all`, `.unread`, `.exploding`)
2. `ConversationsListItem` — Update to show pending state subtitle
3. `ConversationViewModel` — Ensure it properly handles pending conversations
4. `NewConversationView` — Remove the "This convo will appear on your home screen after someone approves you" confirmation dialog (line 62) since pending invites now appear immediately on the home screen

### Data Model

No new database fields needed. Existing fields are sufficient:
- `Conversation.isDraft: Bool` — Indicates draft/placeholder state (checks `draft-` prefix on `id` and `clientConversationId`)
- `Conversation.hasJoined: Bool` — Computed from members list
- `Conversation.invite: Invite?` — Contains invite metadata (hydrated from `DBInvite` via `conversationInvite?.hydrateInvite()`)

**Note**: `Conversation` does **not** currently have an `isUnused` property — that field only exists on `DBConversation` and is filtered out at the repository level. This is correct; unused pre-created conversations should never appear in the UI.

A new computed property:

```swift
public extension Conversation {
    var isPendingInvite: Bool {
        isDraft && !hasJoined
    }
}
```

**Note**: The `invite` property on `Conversation` represents the invite created by the *local user's* inbox member. For a joiner (the pending invite case), `invite` is always `nil` because the joiner didn't create an invite — the conversation creator did. Therefore `isPendingInvite` cannot rely on `invite != nil`. The `isDraft && !hasJoined` check is sufficient because true drafts (user creating a new conversation) always have the current user as a member (`hasJoined == true`).

### Current Filtering Logic

**Current behavior in `ConversationsRepository.swift`** (the private `Database.composeAllConversations` extension):
```swift
func composeAllConversations(consent: [Consent]) throws -> [Conversation] {
    let dbConversationDetails = try DBConversation
        .filter(!DBConversation.Columns.id.like("draft-%"))
        .filter(consent.contains(DBConversation.Columns.consent))
        .filter(DBConversation.Columns.expiresAt == nil || DBConversation.Columns.expiresAt > Date())
        .filter(DBConversation.Columns.isUnused == false)
        .detailedConversationQuery()
        .fetchAll(self)
    return try dbConversationDetails.composeConversations(from: self)
}
```

Four filters are applied:
1. `!id.like("draft-%")` — Excludes all drafts (including pending invites) ← **this is what we need to modify**
2. `consent.contains(consent)` — Only shows allowed conversations
3. `expiresAt == nil || expiresAt > Date()` — Excludes expired conversations
4. `isUnused == false` — Excludes pre-created unused conversations (added in #382)

**Proposed change:**
- Modify filter 1 to allow pending invites through while still excluding true drafts
- A pending invite has: `id LIKE 'draft-%'` AND `inviteTag IS NOT NULL` AND `inviteTag != ''`
- A true draft (user creating new conversation) or unused pre-created conversation: `id LIKE 'draft-%'` AND (`inviteTag IS NULL` OR `inviteTag == ''`)
- Filter 4 (`isUnused == false`) already keeps pre-created conversations out, so we only need to handle true drafts

**Updated filter logic:**
```swift
// Allow non-drafts, OR drafts that are pending invites (have an inviteTag)
.filter(
    !DBConversation.Columns.id.like("draft-%")
    || (DBConversation.Columns.inviteTag != nil
        && length(DBConversation.Columns.inviteTag) > 0)
)
```

### Interaction with Existing Systems

#### Pending Invite Lifecycle (from #8628a98)
- `InboxLifecycleManager` caps awake pending invite inboxes to `maxAwakePendingInvites` (default 3)
- Stale pending invites (> 7 days) are detected and can be deleted via `PendingInviteDebugView`
- Invites with > 1 member (user was actually added) are never auto-deleted
- **Impact**: Pending invites shown in the home view should respect this lifecycle. If a stale invite is deleted, it should disappear from the list via the existing `ValueObservation` publisher.

#### Pre-created Conversations (#382)
- The `isUnused` flag on `DBConversation` distinguishes pre-created conversations from user-visible ones
- `isUnused == false` filter in `composeAllConversations` already handles this correctly
- **No conflict**: Pre-created conversations are unused and have no `inviteTag`, so they won't match the pending invite filter

#### Conversation Display Names (ADR 007)
- Pending invite conversations may have very few members (often just the creator or nobody from the joiner's perspective)
- The display name will follow ADR 007 resolution: custom name → member names → "New Convo"
- If the conversation has a custom name set by the creator, it will display correctly
- If not, it may show as "New Convo" or "Somebody" depending on visible members

#### Exploding Conversations / Time Bombs (#419)
- A new `.exploding` filter was added to `ConversationFilter` enum
- Our `.pendingInvites` filter should follow the same pattern
- Pending invite conversations cannot have scheduled explosions (they're drafts), so they naturally won't appear in the exploding filter

### UI/UX

#### Screens Affected
- `ConversationsView` (home view) — filter toolbar
- `ConversationsListItem` (individual conversation row) — pending state subtitle
- `ConversationView` (conversation detail — already shows `InviteAcceptedView` when pending)
- `FilteredEmptyStateView` — needs an empty state message for pending invites filter

#### Visual Treatment

**ConversationsListItem should show for pending invites:**
- Title: Conversation name (via ADR 007 display name resolution)
- Subtitle: "Awaiting verification" (instead of last message / relative date)
- Avatar: Normal conversation avatar (uses `ConversationAvatarView`)
- Badge: No unread badge (empty conversation)
- Explosion badge: None (pending invites can't have scheduled explosions)

#### Swipe Actions for Pending Conversations
- **Delete** (leading swipe): Should work — calls `leave(conversation:)` which deletes the inbox
- **Explode** (leading swipe): Should NOT appear — conversation is not created by the current user (they're joining)
- **Read/Unread toggle** (trailing swipe): Should be disabled or hidden — no messages to read
- **Mute** (trailing swipe): Should be disabled — requires real conversation ID which doesn't exist yet

#### Context Menu for Pending Conversations
- Pin/Unpin: Allow for consistency
- Mute: Disable (requires real conversation ID)
- Read/Unread: Disable (no messages)
- Explode/Schedule explosion: Disable (not the creator)
- Delete: Allow

#### Filter Toggle
Add `.pendingInvites` to the existing `ConversationFilter` enum:
```swift
enum ConversationFilter {
    case all
    case unread
    case exploding
    case pendingInvites  // NEW

    var emptyStateMessage: String {
        switch self {
        // ...existing cases...
        case .pendingInvites:
            return "No pending invites"
        }
    }
}
```

The filter icon toolbar (in `ConversationsView`) already supports `.unread` and `.exploding` — add a third option for `.pendingInvites` following the same popup/context menu pattern.

#### Navigation Flow
1. User accepts invite via QR code or link
2. `ConversationStateMachine` creates placeholder conversation (`isDraft: true`)
3. Conversation appears in home view with "Awaiting verification" subtitle
4. User taps pending conversation from home view
5. Opens `ConversationView` (same view as regular conversations)
6. `ConversationOnboardingView` displays `InviteAcceptedView` showing "Invite accepted" message with delayed description: "See and send messages after someone approves you."
7. When approved, conversation updates to `isDraft: false`, `hasJoined: true`
8. Conversation list item and detail view update to show normal state

**Important**: Pending invites use the same `ConversationView` as regular conversations — no separate view is needed. The onboarding coordinator handles showing the appropriate UI state.

### Edge Cases to Consider

1. **Multiple pending invites**: User could have several pending invites (capped at `maxAwakePendingInvites` = 3 awake at a time, but all should display in the list regardless of wake state)
2. **Expired invites**: What if the invite expires before approval? (Already handled by `expiresAt` filter in the repository)
3. **Stale invites (> 7 days)**: `InboxLifecycleManager` detects these; if auto-deletion is enabled in the future, they'll disappear from the list. Currently they persist and are visible in `PendingInviteDebugView`
4. **Denied invites**: If the creator denies, conversation should be removed (existing behavior)
5. **App backgrounding**: Ensure real-time updates work when conversation is approved while app is backgrounded — `ValueObservation` publisher should handle this
6. **Pre-created unused conversations**: Must NOT appear — the `isUnused == false` filter handles this
7. **Conversations with `kind == .dm`**: Currently `ConversationsViewModel` filters out DMs with `$0.kind == .group`. Pending invites should also be groups (invites are only for group conversations), but verify this holds.

## Implementation Plan

### Phase 1: Core Data & Filtering
- [ ] Add `isPendingInvite` computed property to `Conversation` model
- [ ] Modify `Database.composeAllConversations()` in `ConversationsRepository.swift` to include pending invites (drafts with a non-empty `inviteTag`) while continuing to exclude true drafts
- [ ] Verify `isUnused == false` filter correctly excludes pre-created conversations
- [ ] Ensure pending invite conversations have required associations (creator, localState, members) for `detailedConversationQuery()` to succeed
- [ ] Add unit tests for repository filtering logic

### Phase 2: UI Updates — List Item
- [ ] Update `ConversationsListItem` to detect `isPendingInvite` and show "Awaiting verification" subtitle instead of last message
- [ ] Conditionally hide/disable swipe actions for pending conversations (no explode, no read/unread, no mute)
- [ ] Conditionally disable context menu actions for pending conversations
- [ ] Ensure `ConversationViewModel` properly handles pending conversations when tapped
- [ ] Remove the "This convo will appear on your home screen after someone approves you" confirmation dialog from `NewConversationView.swift` (line 62)
- [ ] Update SwiftUI previews for pending state

### Phase 3: Filter Toggle
- [ ] Add `.pendingInvites` case to `ConversationFilter` enum in `ConversationsViewModel`
- [ ] Add filter logic to `pinnedConversations` and `unpinnedConversations` computed properties
- [ ] Add filter button to `ConversationsView` toolbar (following existing `.unread` / `.exploding` pattern)
- [ ] Add `FilteredEmptyStateView` message for "No pending invites"
- [ ] Ensure filter resets to `.all` when no pending invites exist (matching existing behavior for unpinned conversations)

### Phase 4: Polish & Edge Cases
- [ ] Test transition from pending to joined state (draft → real conversation)
- [ ] Verify `ConversationOnboardingCoordinator` interaction when opening pending invite from home view
- [ ] Test with stale invites (> 7 days) — should still display
- [ ] Test filter toggle behavior with empty states
- [ ] Verify pending invites don't appear in `.exploding` filter
- [ ] Test that pre-created unused conversations don't leak into the list
- [ ] Add manual test scenarios for QA

## Testing Strategy

### Unit Tests
- `ConversationsRepository`: Verify draft filtering includes pending invites but excludes true drafts and unused conversations
- `Conversation` model: Test `isPendingInvite` computed property with various combinations of `isDraft`, `hasJoined`, and `invite`
- `ConversationsViewModel`: Ensure pending conversations are included in list and respect all filter modes

### Integration Tests
- Create a pending invite and verify it appears in home view
- Accept an invite and verify conversation transitions from pending to joined
- Test real-time updates when invite is approved
- Test with pre-created unused conversations to ensure they don't appear

### Manual Testing Scenarios
1. Accept an invite via QR code, verify it appears in home view
2. Accept invite via link, verify it appears in home view
3. Tap pending conversation, verify `InviteAcceptedView` is shown
4. Wait for approval (or simulate), verify conversation updates to normal state
5. Test with multiple pending invites (up to the cap and beyond)
6. Test expired invite behavior
7. Test stale invite behavior (> 7 days)
8. Test app backgrounding/foregrounding during pending state
9. Verify pending invites sort chronologically by `createdAt`
10. Verify mute/read-unread actions are disabled for pending conversations
11. Test filter toggle to show only pending invites
12. Test filter toggle with zero pending invites (empty state)
13. Verify pre-created unused conversations never appear
14. Test explode swipe action does NOT appear for pending invites

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Users confused by pending conversations | Medium | Clear visual treatment and "Awaiting verification" status text |
| Performance impact from including drafts | Low | Drafts are minimal in number (capped at 3 awake), negligible impact |
| Filtering logic breaks other draft use cases | High | Thorough testing of draft conversation creation flow + unused conversation exclusion |
| Real-time updates don't trigger UI refresh | Medium | Verify `ValueObservation` updates propagate correctly through the existing `conversationsPublisher` pipeline |
| Pre-created conversations leak into the list | High | `isUnused == false` filter already guards this; add explicit tests |
| `detailedConversationQuery()` fails for pending invite conversations (missing required associations) | Medium | Pending invite conversations have a creator and localState from creation; verify members association works with `including(all:)` even if empty |

## Decisions

- [x] **Sort order**: Chronological by `COALESCE(lastMessage.date, conversation.createdAt) DESC` with other conversations (pending invites have no messages so they sort by `createdAt`)
- [x] **Count badge**: No count badge for pending invites (empty conversation)
- [x] **Pinning**: Allow pinning for consistency
- [x] **Read/unread toggle**: Disable for pending invites (no messages)
- [x] **Muting**: Disable mute action for pending invites (requires real conversation ID which doesn't exist yet)
- [x] **Explode action**: Do not show for pending invites (user is not the creator)
- [x] **Filter toggle**: Yes, add `.pendingInvites` filter alongside existing `.unread` and `.exploding`
- [x] **Sending messages**: Already handled by state machine (blocked while pending)
- [x] **Subtitle text**: "Awaiting verification"
- [x] **Display name**: Follows ADR 007 — custom name if set, otherwise member name formatting or "New Convo"

## References

- Existing code: `ConversationStateMachine.swift` (invite join flow)
- Existing code: `InviteAcceptedView.swift` (pending UI component)
- Existing code: `ConversationOnboardingCoordinator.swift` (onboarding state management — includes assistant hint flow added in #503)
- Existing code: `PendingInviteRepository.swift` (tracks pending invites per inbox, includes `PendingInviteDetail` with member count)
- Existing code: `PendingInviteDebugView.swift` (debug view for inspecting/deleting pending invites)
- Existing code: `InboxLifecycleManager.swift` (pending invite cap at 3 awake, stale invite detection at 7 days)
- ADR 007: Default conversation display name and emoji
- PR #382: Pre-create conversations along with inboxes (added `isUnused` flag)
- PR #419: Scheduled explosion / Time Bomb (added `.exploding` filter)
- PR #8628a98: Cap pending invite inboxes, expire stale ones, and add debug view
