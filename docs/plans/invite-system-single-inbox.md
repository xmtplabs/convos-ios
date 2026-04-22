# Invite System: Single-Inbox Redesign

> **Status**: Draft
> **Date**: 2026-04-16
> **Depends on**: `docs/plans/single-inbox-identity-refactor.md` (must land before C10)
> **Related ADRs**: ADR 001 (primary), ADR 002 (superseded by refactor), ADR 005

## Summary

The per-conversation identity model (ADR 002) gave the invite system two privacy properties for free: sender-side anonymity (each conversation had its own inbox, so the invite revealed nothing beyond that conversation) and joiner-side anonymity (the joiner created a fresh inbox per join, so the creator learned nothing about the joiner's other activity). Both properties are gone in the single-inbox world, because every user now has one permanent inbox ID.

This plan covers what actually changes in the invite system for single-inbox, which is less than originally scoped. The privacy regressions are real but cannot be fixed within XMTP's current infrastructure. The real work is honest documentation of the new posture and minor code simplifications.

## Background: What the C10 Shim Does

The C10 checkpoint in the main refactor ships a minimum-viable shim:

- Accept-invite flow adds the user's single inbox to the existing group (no new inbox created)
- Invite token format and cryptographic structure unchanged
- `JoinRequest` content type continues to work; payload reflects the global profile
- `PendingInviteRepository` simplified (`clientId` scoping removed)

The shim keeps invites working during the refactor. This plan addresses the remaining follow-up.

## Privacy Model Changes

### What we lose from ADR 002

| Property | Old model | New model |
|----------|-----------|-----------|
| Creator inbox ID in invites | Single-purpose — reveals only this conversation | Permanent identity — visible to anyone with the invite link |
| Joiner inbox ID exposed to creator | Fresh per-join — reveals nothing | Permanent identity — visible to creator and all group members |
| Joiner link to other conversations | None (fresh inbox) | Possible if any member stores the inbox ID |

### What we keep

- Conversation ID encrypted in invite token (ChaCha20-Poly1305 + HKDF, unchanged)
- Invite tag prevents adding joiner to unrelated conversations (unchanged)
- Spam protection via DM blocking on invalid join requests (unchanged)
- Decentralized validation: no backend required (unchanged)

## Goals

1. Simplify invite code for the single-inbox architecture (remove `clientId` scoping, remove per-conversation keypair machinery that no longer applies).
2. Honestly document the privacy posture: both regressions are acknowledged, neither is papered over.

## Non-Goals

- Hiding the creator's permanent inbox ID from the invite payload. The joiner needs the creator's inbox ID to route the join-request DM — there is no way to remove it without a relay or protocol-level change outside our scope.
- Preventing the creator (or any group member) from learning the joiner's permanent inbox ID. XMTP group membership is transparent to all members by the MLS protocol: once added, the joiner's inbox ID is visible to everyone regardless of how they arrived. This cannot be fixed at the application layer.
- Multi-device invite management (deferred alongside multi-device UX)
- Invite analytics or link-click tracking
- Server-side invite validation

## Remaining Work

### 1. Invite tag storage in `appData`

**Current**: Invite tags are stored in XMTP group `appData` (via `ConvosAppData`). This is unchanged by the single-inbox refactor.

**Concern raised in main plan**: "Invite tag storage reconsideration (currently in appData)."

**Assessment**: The `appData` storage for invite tags works correctly in the single-inbox world. The 8KB limit is not a concern because profiles have moved to XMTP messages (ADR 005). No change is required in this phase. The `ConvosAppData` package is retained with slimmer scope as confirmed by the main plan.

### 2. Notification routing for pending invites

**Current**: Pending invites are associated with a `clientId` → inbox mapping. The NSE uses `clientId` to look up the correct identity.

**After C10 shim**: `clientId` scoping removed from `PendingInviteRepository`. Pending invites are associated with the single user identity.

**Remaining work**: Verify that push notifications for incoming join request DMs are routed correctly to the single identity's DM processing path. The NSE reads the singleton keychain identity (done in C7). The only remaining question is whether `InviteJoinRequestsManager` needs any update to subscribe to the correct DM stream after the single-inbox pivot. Tracked as part of C10 implementation verification.

### 3. ADR 001 privacy section update

After C10 shim lands and this plan is approved, update ADR 001 with:

- A "Privacy Model in the Single-Inbox World" section replacing the current "Note on Creator Inbox ID Exposure" (which was valid under ADR 002 but is no longer accurate).
- Explicit acknowledgment that the creator's inbox ID is now a permanent identity exposed to anyone with the invite link.
- Explicit acknowledgment that all group members, including the creator, see the joiner's permanent inbox ID after joining (MLS requirement).
- Removal of any language suggesting these properties can be recovered at the application layer.

This update lands at C10.

## Checkpoint Dependencies

| This plan item | Depends on |
|----------------|------------|
| appData storage (§1) | No change needed |
| Notification routing verification (§2) | C7 (NSE), C10 |
| ADR 001 privacy section update (§3) | C10 |

## Files Affected

| File | Change |
|------|--------|
| `docs/adr/001-invite-system-architecture.md` | Privacy model update (at C10) |

## Related Documents

- `docs/plans/single-inbox-identity-refactor.md` — parent plan; C10 ships the shim this plan builds on
- `docs/adr/001-invite-system-architecture.md` — invite system architecture
- `docs/adr/002-per-conversation-identity-model.md` — superseded; historical context for the privacy properties lost in this transition
