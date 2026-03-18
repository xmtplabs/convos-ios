# Feature: Inactive Conversation Mode (Post-Restore)

> **Status**: Draft
> **Author**: PRD Writer Agent
> **Created**: 2026-03-18
> **Updated**: 2026-03-18

## Overview

After a user restores their account from a backup, all their conversations are in an inactive (read-only) state per the MLS protocol. XMTP requires the new installation to be re-added to each conversation by another participant before it becomes fully active. This feature surfaces that state clearly in the UI so users understand why interactions are temporarily unavailable, and automatically clears the state when the conversation becomes active again.

## Problem Statement

Today, a restored user sees their conversations in the list with no indication that anything is different. If they try to send a message or interact, they get unexpected behavior or silent failure. There is no explanation of why the conversation is unresponsive, and no signal about when it will recover. This creates confusion and erodes trust in the restore experience.

## Goals

- [ ] Give users a clear, honest explanation of why a restored conversation is temporarily limited
- [ ] Prevent accidental interaction with inactive conversations (reactions, replies, send) without blocking view access to history
- [ ] Surface the inactive state in both the conversations list and conversation detail
- [ ] Automatically clear the inactive state when the conversation becomes active again (another member sends a message)
- [ ] Reuse existing patterns and components wherever possible (Verifying state, `isPendingInvite` precedent)

## Non-Goals

- Not implementing any new XMTP protocol mechanism to force reactivation
- Not supporting user-triggered reactivation (this is driven by other members)
- Not adding a separate "Restored" section or filter tab to the conversations list
- Not adding visual treatment to individual historical messages from before the backup
- Not posting a group status update message when a restore happens (restore is private)
- Not handling multi-device scenarios (this is for the single-device restore path)

## User Stories

### As a user who just restored their account, I want to understand why I cannot interact with my conversations so that I am not confused or worried

Acceptance criteria:
- [ ] Conversations restored from backup show a clear inactive state indicator in the list subtitle
- [ ] Opening a restored conversation shows a banner explaining the limited state
- [ ] The composer area is visually muted to signal unavailability
- [ ] Tapping any interactive element (send, reaction, swipe-to-reply) shows an alert explaining the state instead of silently failing

### As a user whose restored conversation has become active again, I want the UI to return to normal without needing to restart the app

Acceptance criteria:
- [ ] When another member sends a message, the inactive banner and muted composer disappear reactively
- [ ] The conversation list item returns to normal subtitle display
- [ ] No manual refresh or restart is required

## Design Summary

The design mirrors the existing "Verifying" state pattern (`isPendingInvite`) already present in the app. Two surfaces are affected.

### Conversations list

The list item subtitle shows the inactive indicator inline, following the same pattern as "Verifying" — a relative date followed by a dot separator and a short status label. The exact wording is pending designer sign-off (see Open Questions).

### Conversation detail

A pill/banner is pinned above the composer when the conversation is inactive. The banner contains:
- An SF Symbol icon in lava/red color (exact symbol pending — see Open Questions)
- A bold primary-color title (e.g., "History restored" or "Restored from backup" — pending)
- Secondary-color subtext describing what the user needs to do (e.g., "You can see and send new messages after another member comes online")
- The banner is tappable and links to a "learn site" URL (URL TBD — see Open Questions)

The composer area is visually muted: the avatar renders at reduced opacity and the text field uses an inactive color (`#d9d9d9`). The composer is not hidden — the history is fully readable.

### Alert (interactive element interception)

When the user taps any element that would normally trigger an interaction (send, reaction, swipe-to-reply), an alert is shown instead:
- Title: "Awaiting reconnection"
- Body: "You can see and send new messages, reactions and more after another member comes online."
- Button: "Got it"

## Open Questions for Courter

These need designer sign-off before implementation begins.

- [ ] **Banner title wording**: Two frames show different copy — "History restored" vs "Restored from backup". The Loom transcript also mentions "Awaiting reconnection" (used only in the alert). What is the final intended title for the banner?

- [ ] **Banner icon**: The first Figma frame uses `cloud.fill` (`􀇃`), the second uses a different symbol that appears to be a checkmark badge or clock (`􀢔`). Which SF Symbol is intended?

- [ ] **Subtext wording**: "See and send messages after another member comes online" vs "You can see and send new messages after another member comes online" — which is the intended copy for the banner subtext?

- [ ] **Composer tap behavior**: The design shows the composer area visually muted. Should tapping anywhere in the composer (including the text field) trigger the "Awaiting reconnection" alert? Or should the text field remain interactive and only the send button be blocked?

- [ ] **Learn site URL**: Tapping the banner takes the user to a "learn site". What is the URL?

- [ ] **Conversations list indicator wording**: Should the inactive subtitle label match the banner title ("History restored"), use something shorter like "Restoring", or match the existing short-word pattern ("Verifying")?

- [ ] **Reactivation transition**: When the conversation becomes active and the banner disappears, should this be a silent removal, or should there be any visual feedback (e.g., a brief animation, a toast)?

- [ ] **Historical message interactivity**: The design has a hidden Figma layer labelled "Restored messages are not interactive yet". Is fading or otherwise treating individual historical messages in scope for this feature, or is it explicitly out of scope?

## Technical Implementation Plan

### Phase 1: Data model

Add an `isActive: Bool` flag surfaced on `Conversation` and stored in the existing `ConversationLocalState` table.

`isActive()` state lives in the XMTP SQLite database — it is an MLS-level concept and is not currently stored anywhere in our GRDB. We need it in GRDB because our UI is driven entirely by GRDB `ValueObservation`: without a DB column, we have no reactive path from XMTP state → ViewModel → View. Calling `isActive()` on demand is not viable because it requires a live XMTP client and cannot drive reactive UI.

`ConversationLocalState` is the right home for this flag — it already holds temporary UI-driving state (`isUnread`, `isPinned`, `isMuted`) in a separate table keyed by `conversationId`. The `ConversationLocalStateWriter` is the natural place to add the write path, keeping the pattern consistent.

This means Phase 1 requires:
- A new `isActive` column on `ConversationLocalState` with a GRDB migration (default `true`, so all existing rows are unaffected)
- `isActive: Bool` surfaced on `Conversation` (read from `ConversationLocalState` join, like the other local state flags)
- `setActive(_ value: Bool, for conversationId: String)` added to `ConversationLocalStateWriterProtocol` and `ConversationLocalStateWriter` — follows the same `updateLocalState` helper pattern already used by `setUnread`, `setPinned`, `setMuted`
- A bulk variant `markAllConversationsInactive()` (no conversation ID argument) that sets `isActive = false` for every row in `ConversationLocalState` in a single write transaction — needed by `RestoreManager` which operates on all conversations at once

The bulk write happens in `RestoreManager` right after `importConversationArchives` completes and before `finishRestore()` resumes sessions.

**Key files:**
- `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift` — surface `isActive: Bool`
- `ConversationLocalState` DB record — add `isActive` column + migration
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationLocalStateWriter.swift` — add `setActive` and `markAllConversationsInactive` to protocol + implementation
- `ConvosCore/Sources/ConvosCore/Backup/RestoreManager.swift` — call `markAllConversationsInactive()` after `importConversationArchives`

### Phase 2: Reactivation detection

Reactivation happens when another participant **sends a message** — their XMTP client detects our new installation and issues an MLS commit re-adding it to the group. Our device receives a **welcome message** during the next `syncAllConversations` call, after which `isActive()` returns `true`.

Detection is therefore hooked into `SyncingManager` immediately after each `syncAllConversations` call, not on individual message receipt. There are three call sites in `SyncingManager.swift`:

1. **Initial sync** (after streams are subscribed, during `start`)
2. **Resume sync** (after `syncAllConversations` on `resume`)
3. **Discovery sync** (`requestDiscovery` / `scheduleDelayedDiscovery`)

After each of these calls completes, query the DB for all conversations with `isActive == false`. For each, call `conversation.isActive()` on the XMTP SDK — this is a local MLS state check, no network required. If it returns `true`, call `setActive(true, for: conversationId)` to update GRDB.

The GRDB `ValueObservation` pipeline propagates the change to the ViewModel and view reactively — no polling required, no restart needed.

Only conversations with `isActive == false` are checked; this is a no-op for non-restored conversations.

**Key files:**
- `ConvosCore/Sources/ConvosCore/Syncing/SyncingManager.swift` — add reactivation check after each `syncAllConversations` call site (initial, resume, discovery)
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationLocalStateWriter.swift` — `setActive(true, for: conversationId)` reactivates per conversation
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/ConversationRepository.swift` — add a query to fetch IDs of all conversations where `isActive == false`

### Phase 3: Conversations list UI

Update `ConversationsListItem` to detect `isActive` and show the inactive indicator in the subtitle, following the existing `isPendingInvite` / "Verifying" pattern. The exact label wording is pending design sign-off.

The indicator sits in the same inline subtitle position as "Verifying": relative date, dot separator, status label.

**Key files:**
- `Convos/Conversations List/ConversationsListItem.swift` — add `isActive` branch to subtitle rendering (alongside existing `isPendingInvite` branch)

### Phase 4: Conversation detail UI

Four UI concerns in `ConversationView` / `ConversationViewModel`:

1. **Banner**: Show the pinned pill above the composer when `isActive == false`. The banner is a new view component that takes the icon, title, subtext, and a tap action (opening the learn site URL). It disappears reactively when `isActive` flips to `true`.

2. **Muted composer**: When `isActive == false`, render the composer in its muted visual state (avatar at reduced opacity, text field in inactive color). This is a visual-only change driven by the flag.

3. **Interactive element interception**: When `isActive == false`, tapping send, a reaction, or swipe-to-reply shows the "Awaiting reconnection" alert instead of executing the action. The interception point is in the ViewModel action handlers — check the flag and route to an alert state rather than executing.

4. **Alert state**: Add an `isShowingReconnectionAlert: Bool` to `ConversationViewModel` (or equivalent alert-driving mechanism). The alert is dismissed with "Got it".

**Key files:**
- `Convos/Conversation Detail/ConversationView.swift` — insert banner above composer, pass muted state to composer, wire alert
- `Convos/Conversation Detail/ConversationViewModel.swift` — expose `isActive`, add interception logic and alert state
- New view component (e.g., `InactiveBanner.swift`) — the pill/banner UI

## Testing Strategy

- Unit tests for `RestoreManager`: verify all conversations are marked `isActive = false` after restore
- Unit tests for `SyncingManager`: verify that after `syncAllConversations` completes, conversations with `isActive == false` are checked via `isActive()`, the flag is set to `true` when the SDK returns true, and left unchanged when the SDK returns false
- Unit tests for `Conversation` model: verify `isActive` is correctly read from DB state
- Manual testing scenarios:
  1. Complete a restore flow, open conversations list — all restored conversations show the inactive indicator
  2. Open a restored conversation — banner appears above composer, composer is muted
  3. Tap send — alert appears with "Awaiting reconnection" copy, dismisses with "Got it"
  4. Tap a reaction — same alert
  5. Swipe to reply — same alert
  6. Tap the banner — learn site URL opens
  7. Simulate another member sending a message — on the next `syncAllConversations` cycle, `isActive()` returns true, banner disappears, composer restores, list item returns to normal
  8. Open a non-restored conversation — no banner, no muted state

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `isActive()` returns false for a healthy conversation not from a restore | Low | Flag is only ever set at restore time; non-restored conversations will never have `isActive = false` |
| Flag is never cleared if no one sends a message (quiet conversation) | Medium | Banner persists — acceptable for v1. Reactivation requires another participant to send; the user cannot force it. Could add a manual "check" action later if needed |
| `isActive()` check adds latency to sync path | Low | Local MLS state check, no network call. Only runs for conversations with `isActive == false`, which is empty after all conversations reactivate |
| Design copy/icon not finalized before implementation | Medium | Phase 3 and 4 can use placeholder strings/symbols behind a constant; finalizing design answers unblocks the final pass |
| User confusion if banner never disappears (no active members) | Medium | Copy addresses this ("after another member comes online"); can also explore a later enhancement to detect reactivation via periodic sync |

## References

- Existing pattern: `isPendingInvite` in `Conversation.swift` and `ConversationsListItem.swift`
- Existing pattern: "Verifying" subtitle in `ConversationsListItem.swift`
- `ConvosCore/Sources/ConvosCore/Backup/RestoreManager.swift` — restore entry point
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` — message processing entry point
- `ConvosCore/Sources/ConvosCore/Storage/Models/Conversation.swift` — model to extend
- Related plan: `docs/plans/icloud-backup.md` — restore flow architecture
- Related plan: `docs/plans/vault-archive-backup.md` — vault restore details
