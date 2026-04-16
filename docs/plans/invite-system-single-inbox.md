# Invite System: Single-Inbox Redesign

> **Status**: Draft
> **Date**: 2026-04-16
> **Depends on**: `docs/plans/single-inbox-identity-refactor.md` (must land before C10)
> **Related ADRs**: ADR 001 (primary), ADR 002 (superseded by refactor), ADR 005

## Summary

The per-conversation identity model (ADR 002) gave the invite system two properties for free: sender-side privacy (the creator's inbox ID appeared in invites, but each inbox was single-purpose so it revealed nothing beyond the conversation itself) and joiner-side anonymity (the joiner created a fresh inbox, so the creator learned nothing about the joiner's other conversations). Both properties disappear in the single-inbox world, because every user now has one permanent inbox ID.

This plan covers the full redesign of the invite system for the single-inbox world, working within XMTP's infrastructure and Convos' decentralized philosophy. It is scoped to changes that must land before or alongside invite code changes beyond the minimum shim in C10.

## Background: What the C10 Shim Does

The C10 checkpoint in the main refactor ships a minimum-viable shim:

- Accept-invite flow adds the user's single inbox to the existing group (no new inbox created)
- Invite token format and cryptographic structure unchanged
- `JoinRequest` content type continues to work; payload reflects the global profile
- `PendingInviteRepository` simplified (`clientId` scoping removed)

The shim keeps invites working during the refactor but does not address the privacy model changes. This plan addresses those.

## Privacy Model Changes

### What we lose from ADR 002

| Property | Old model | New model |
|----------|-----------|-----------|
| Creator inbox ID in invites | Single-purpose — reveals only this conversation | Permanent identity — must be hidden |
| Joiner inbox ID exposed to creator | Fresh per-join — reveals nothing | Permanent identity — must be hidden |
| Joiner link to other conversations | None (fresh inbox) | Possible if creator stores the inbox ID |

### What we keep

- Conversation ID encrypted in invite token (ChaCha20-Poly1305 + HKDF, unchanged)
- Invite tag prevents adding joiner to unrelated conversations (unchanged)
- Spam protection via DM blocking on invalid join requests (unchanged)
- Decentralized validation: no backend required (unchanged)

## Goals

1. Remove the creator's permanent inbox ID from the invite payload.
2. Prevent the creator from learning the joiner's permanent inbox ID at join time.
3. Preserve: decentralized validation, invite tag protection, spam resistance, revocability, QR code shareability.
4. Keep token format change backward-compatible where possible, or define a versioned migration path.

## Non-Goals

- Multi-device invite management (deferred alongside multi-device UX)
- Invite analytics or link-click tracking
- Server-side invite validation

## Proposed Changes

### 1. Remove creator inbox ID from invite payload

**Current**: `InvitePayload.creatorInboxId` (32 bytes) is embedded as the AAD for token encryption and the DM routing destination.

**Problem**: In the single-inbox world, this field exposes the creator's permanent identity to anyone who possesses the invite link.

**Solution**: Replace the embedded inbox ID with an ephemeral key pair.

- At invite creation, generate a short-lived **invite keypair** (secp256k1 or X25519).
- Include the **public key** (33 bytes compressed) in the invite payload in place of the inbox ID.
- Use the public key as the AAD for ChaCha20-Poly1305 (replacing `info = "inbox:<inboxId>"`).
- Register a mapping `invite_public_key → actual_inbox_id` locally so the creator can route incoming join request DMs.
- Rotate the invite keypair when the invite tag is rotated (lock convo, revoke).

This approach keeps the invite compact (same size range), preserves the cryptographic binding, and reveals only an ephemeral key rather than a permanent identity.

**Wire format change**: `InvitePayload.creator_inbox_id` (field 3) becomes `InvitePayload.creator_invite_pubkey` (field 3, renamed). Version byte in the slug encoding bumps to `0x02` to distinguish from old invites.

**Backward compatibility**: Old clients holding `0x01` invites can still process them; new clients accept both. After a forced-update horizon (TBD), old invite generation can be deprecated.

**Implementation files**:
- `ConvosInvites/Sources/ConvosInvitesCore/Core/invite.proto` — new field
- `ConvosInvites/Sources/ConvosInvitesCore/Core/InviteToken.swift` — AAD change
- `ConvosInvites/Sources/ConvosInvitesCore/Core/InviteSigner.swift` — keypair generation + storage
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift` — generation path
- Local DB or Keychain: ephemeral key → inbox ID mapping (small table, pruned on invite rotation)

### 2. Hide joiner's inbox ID from creator at join time

**Current**: When a joiner sends a join request DM to the creator, the DM comes from the joiner's XMTP inbox. In the old model this was a fresh single-purpose inbox; in the new model it is the joiner's permanent identity.

**Problem**: The creator's client sees the sender field of the DM, which is the joiner's permanent `inboxId`. Even if we do not store it, the creator's app now knows the joiner's global identity.

**Options considered**:

| Option | Privacy | Complexity | Notes |
|--------|---------|------------|-------|
| A. Accept the exposure | Low | Zero | Joiner joins as permanent self; creator sees full identity |
| B. Blind DM via a relay conversation | High | High | Extra XMTP group for routing; latency |
| C. Include a DM-routing ephemeral key in the invite; joiner DMs to it | Medium | Medium | Creator generates ephemeral DM inbox; joiner DMs it; creator correlates via invite tag |
| D. Join request sent via group add + proof (no DM) | High | High | Requires protocol-level support |

**Recommendation — Phase 1 (launch with C10)**: Accept Option A. The joiner's inbox ID is visible to the creator at join time. Document this as a known privacy regression from ADR 002 and a deliberate tradeoff in the single-inbox world. Record in the "privacy properties we lose" update to ADR 002.

**Phase 2 (post-launch)**: Evaluate Option C. The creator embeds an ephemeral DM routing key in the invite; the joiner sends the join request to a DM derived from that key. The creator maps the incoming DM to the conversation via the invite tag. This adds ~1 round-trip latency and complexity but recovers joiner-side anonymity.

### 3. Invite tag storage in `appData`

**Current**: Invite tags are stored in XMTP group `appData` (via `ConvosAppData`). This is unchanged by the single-inbox refactor.

**Concern raised in main plan**: "Invite tag storage reconsideration (currently in appData)."

**Assessment**: The `appData` storage for invite tags works correctly in the single-inbox world. The 8KB limit is not a concern because profiles have moved to XMTP messages (ADR 005). No change is required in this phase. We note that the `ConvosAppData` package is kept for this purpose (the main plan confirms it is retained with slimmer scope).

### 4. Notification routing for pending invites

**Current**: Pending invites are associated with a `clientId` → inbox mapping. The NSE uses `clientId` to look up the correct identity.

**After C10 shim**: `clientId` scoping removed from `PendingInviteRepository`. Pending invites are associated with the single user identity.

**Remaining work**: Verify that push notifications for incoming join request DMs are routed correctly to the single identity's DM processing path. The NSE reads the singleton keychain identity (done in C7). The only remaining question is whether `InviteJoinRequestsManager` needs any update to subscribe to the correct DM stream after the single-inbox pivot. This is tracked as part of C10 implementation verification.

### 5. End-to-end privacy model documentation

After C10 shim lands and this plan is approved, update ADR 001 with:

- A "Privacy Model in the Single-Inbox World" section replacing the current "Note on Creator Inbox ID Exposure" (which was valid under ADR 002 but is no longer).
- Table of remaining threats and mitigations under the new model.
- Pointer to Phase 2 (ephemeral routing key) as the path to recovering joiner anonymity.

## Checkpoint Dependencies

| This plan item | Depends on |
|----------------|------------|
| Ephemeral creator key (§1) | C3 (KeychainIdentityStore), C10 shim |
| Joiner anonymity Phase 2 (§2) | Post-launch; no checkpoint dependency |
| appData storage (§3) | No change needed |
| Notification routing verification (§4) | C7 (NSE), C10 |
| ADR 001 privacy section update (§5) | C10 |

## Implementation Order

1. **Before C10**: This plan is reviewed and approved. No code changes yet.
2. **C10**: Shim lands (existing plan). ADR 001 gets a forward reference to this plan.
3. **Post-refactor (Phase 1)**: Ephemeral creator key generation (§1) — can be a stacked PR on `single-inbox-refactor` or a follow-up feature branch.
4. **Post-refactor (Phase 2)**: Joiner anonymity via ephemeral routing key (§2) — separate feature branch after Phase 1 validates.

## Risks

- **Backward compatibility surface**: Version byte bump (`0x02`) requires all active clients to handle both versions. Define a sunset date for `0x01` invites.
- **Key storage for ephemeral invite keypairs**: Needs a lightweight, prunable local store (not Keychain — too many entries). A small GRDB table is appropriate.
- **Phase 2 complexity**: The ephemeral DM routing key approach requires the joiner to generate a DM conversation with a derived address, which may not map cleanly onto XMTP's DM group model. Requires a spike against the XMTP iOS SDK before committing.

## Open Questions

1. What is the forced-update horizon for `0x01` invite deprecation? (Product decision)
2. Does XMTP's DM model support deriving a DM inbox from an ephemeral public key? (Technical spike for Phase 2)
3. Should the ephemeral invite keypair rotate per-invite or per-conversation? Per-invite gives stronger unlinkability but increases local storage.

## Files Affected

| File | Change |
|------|--------|
| `ConvosInvites/Sources/ConvosInvitesCore/Core/Proto/invite.proto` | Add `creator_invite_pubkey` field |
| `ConvosInvites/Sources/ConvosInvitesCore/Core/InviteToken.swift` | AAD uses pubkey instead of inbox ID |
| `ConvosInvites/Sources/ConvosInvitesCore/Core/InviteSigner.swift` | Keypair generation |
| `ConvosInvites/Sources/ConvosInvitesCore/Core/InviteEncoding.swift` | Version byte `0x02` |
| `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift` | Generation path |
| `ConvosCore/Sources/ConvosCore/Storage/Database Models/` | New `DBInviteKeypair` table |
| `docs/adr/001-invite-system-architecture.md` | Privacy model update (at C10) |

## Related Documents

- `docs/plans/single-inbox-identity-refactor.md` — parent plan; C10 ships the shim this plan builds on
- `docs/adr/001-invite-system-architecture.md` — invite system architecture
- `docs/adr/002-per-conversation-identity-model.md` — superseded; historical context for the privacy properties we are recovering
