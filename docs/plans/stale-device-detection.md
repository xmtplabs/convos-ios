# Stale Device Detection and Recovery Policy

> **Status**: Draft
> **Author**: Louis
> **Created**: 2026-04-07
> **Updated**: 2026-04-07

## Context

After restore on another device, this installation may be revoked for one or more inboxes.

Revocation is the destructive event. Local cleanup on this device is follow-up recovery work.

We want a policy that:
- protects users in lost/stolen-device scenarios,
- handles partial revocation safely,
- keeps UX simple and explicit.

## Goals

- Detect stale installation state using authoritative network checks.
- Differentiate partial stale vs full stale.
- Use one consistent reset action for stale recovery.
- Auto-reset aggressively in full stale.
- Avoid auto-reset in partial stale.

## Non-goals

- Re-pairing from stale state.
- Preserving stale conversations as read-only.
- Remote wipe while device is offline.

## State model

Definitions:
- **Used non-vault inbox**: non-vault inbox with at least one non-unused conversation.
- **Stale used inbox**: used non-vault inbox where `isStale == true`.

Derived states:
- `healthy`: no stale used inboxes.
- `partialStale`: some, but not all, used non-vault inboxes are stale.
- `fullStale`: all used non-vault inboxes are stale.

Computation:
- `U = used non-vault inboxes`
- `S = stale inboxes`
- `staleUsed = U ∩ S`

Rules:
- if `U.count == 0` -> `healthy`
- if `staleUsed.count == 0` -> `healthy`
- if `0 < staleUsed.count < U.count` -> `partialStale`
- if `staleUsed.count == U.count` -> `fullStale`

## Detection source

Keep existing detection source:
- `InboxStateMachine` checks `isInstallationActive()` when inbox becomes ready.
- `InboxStateMachine` checks again on app foreground.

This uses `inboxState(refreshFromNetwork: true)` and compares current installation id to active installation list.

## Policy

### Healthy
- Normal app behavior.

### Partial stale
- Hide stale conversations (existing behavior).
- Keep non-stale conversations visible.
- Do not auto-delete.
- Show persistent stale warning UI with:
  - Primary action: **Continue**
  - Secondary action: **Learn more**
- **Continue action behavior**: run full local reset flow (same flow as full stale cleanup).
- Copy must explicitly state consequence near the button:
  - “Continuing will clear local data on this device and restart setup.”

### Full stale
- Trigger local reset flow automatically as soon as state is confidently `fullStale`.
- No user confirmation required for auto reset.
- If auto reset fails, show blocking recovery UI with:
  - Primary action: **Continue** (retry same reset flow)
  - Secondary action: **Learn more**
- After successful reset, user lands in fresh app setup state.

## Reset flow

Reuse existing delete-all-data/reset path. Do not create a second cleanup implementation.

Required properties:
- idempotent (safe to retry),
- clears local app data and local key material for this app install,
- leaves app in deterministic fresh-start state.

## UX copy guidance

### Partial stale banner
- Title: “Some conversations moved to another device”
- Body: “Continuing will clear local data on this device and restart setup.”
- Actions: `Continue`, `Learn more`

### Full stale blocking state (fallback when auto reset fails)
- Title: “This device has been replaced”
- Body: “This device no longer has access. Continuing will clear local data and restart setup.”
- Actions: `Continue`, `Learn more`

## Edge cases

- **No used inboxes**: do not enter stale UX.
- **Partial -> full transition**: auto-reset only after transition to `fullStale`.
- **Network unavailable**: do not infer stale from missing network; wait for authoritative check.
- **Auto reset race with active UI**: cancel composition/sheets before reset begins.

## Telemetry

Emit events for:
- state transitions: healthy -> partial/full, partial -> full, stale -> healthy,
- auto reset started/succeeded/failed,
- manual continue reset started/succeeded/failed.

## Rollout plan

1. Add derived access state model (`healthy` / `partialStale` / `fullStale`).
2. Wire UI behavior by state.
3. Implement full-stale auto reset trigger.
4. Reuse existing reset flow for both full and partial continue actions.
5. Add unit/UI tests.

## Test plan

- Unit tests for state derivation matrix.
- Unit tests for transition behavior (partial to full).
- UI tests:
  - partial stale shows warning and keeps non-stale conversations visible,
  - continue in partial triggers reset,
  - full stale auto-triggers reset,
  - full stale reset failure shows blocking fallback with continue retry.
- Manual QA for lost-device scenario and mixed-state scenario.

## References

- `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/InboxesRepository.swift`
- `Convos/Conversations List/ConversationsViewModel.swift`
- `docs/plans/vault-re-creation-on-restore.md`
- `docs/plans/icloud-backup.md`
