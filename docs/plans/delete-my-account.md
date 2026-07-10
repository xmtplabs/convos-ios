# PRD: Delete My Account

> **Status**: Draft
> **Created**: 2026-07-10
> **Companion plan**: convos-backend repo, `docs/plans/delete-my-account.md`

## Overview

Turn the existing "Delete all app data" action into a real account deletion:
rename it to "Delete my account", call a new backend deletion endpoint while
the local identity keys still exist, and only then run the local teardown.
The backend endpoint, its deletion barrier, and the server-side teardown are
specified in the companion backend plan; this document owns the client flow,
the deletion state machine, the XMTP lifecycle decisions, the local wipe
manifest, UX, and failure handling.

Two invariants shape everything here:

1. Ordering: backend deletion is authenticated with the identity keys, so it
   must complete before those keys are destroyed.
2. No silent resurrection: nothing the client does after deletion (retries,
   automatic re-authentication, a paired device) may recreate the account.
   The backend's deletion barrier enforces this server-side; the client must
   stop doing the things that would trip it accidentally.

## Problem Statement

Today's "Delete all app data" is a reset, not a deletion. Its only backend
calls are push-topic unsubscription and a single notification-client
unregister; the cold path (no live session) makes no backend calls at all.
The flow then registers a fresh inbox. Everything account-shaped survives on
the server: the account record, auth method, device registrations and push
tokens, credits and ledger, subscription records, uploaded assets, and
connection grants.

The client's own machinery makes a naive fix dangerous: the API client
automatically re-authenticates on a 401, and the backend's SIWE token mint
auto-provisions a fresh account (with a fresh signup bonus) when the auth
method is absent. Without the backend's deletion barrier and matching client
behavior, a deleted account would be silently recreated by the first retry,
background request, or paired device. Deletion is a cross-repo contract, not
a UI rename.

Apple App Store Guideline 5.1.1(v) requires apps that support account
creation to offer in-app account deletion that removes the account record,
not just a local wipe. Convos auto-provisions its backend account without a
sign-up form, but that account is JWT-addressable and carries billing state,
so the safe assumption is that the guideline applies.

There is also a dangling seam: `AuthServiceProtocol.deleteAccount(with:)`
exists with only a mock implementation and no callers. This feature either
wires it for real or removes it in favor of the session-level flow; leaving
an unimplemented deletion stub in the auth protocol is the one outcome this
plan rules out.

## Goals

- [ ] Rename the settings action from "Delete all app data" to "Delete my
      account" and make the name true.
- [ ] Drive the flow from a durable deletion state machine persisted before
      the first backend request, so every crash window has a defined
      recovery.
- [ ] Call the backend deletion endpoint before any local identity or
      keychain teardown, and only proceed to local teardown on confirmed
      success.
- [ ] Never interpret a generic auth failure as deletion confirmation; only
      the backend's terminal identity-deleted response confirms.
- [ ] Disclose, before deletion completes, what is and is not deleted:
      the App Store subscription is not cancelled, some financial records
      are retained, XMTP messages and protocol metadata persist, and
      external purges complete within the backend's published window.
- [ ] Decide and specify the XMTP lifecycle: installations, group
      memberships, and what peers observe.
- [ ] Wipe local state from a versioned, exhaustive manifest (keychain,
      database, defaults, analytics identity), so a reinstall after deletion
      is indistinguishable from a first install.

## Non-Goals

- Cancelling the App Store subscription. Only the user can do that through
  Apple; the flow discloses and links, it does not cancel.
- Deleting XMTP conversation content from the network or from other members'
  devices.
- Remote-wiping other paired devices. The backend's deletion barrier stops
  them from minting new backend tokens; their local data is theirs, and
  their XMTP-layer fate is decided in the XMTP lifecycle section below, not
  by the backend.
- Redesigning the settings screen beyond this action and its confirmation
  flow.

## The ordering invariant

Backend deletion is authenticated by an account-scoped JWT that can only be
minted through a SIWE signature produced with the local identity key. Once
the keychain is wiped, no new token can ever be minted; only an
already-issued token (15-minute TTL) would still work, briefly.

So the invariant is: authentication dies with the keys, therefore the backend
call comes first. The flow is confirm -> backend delete -> confirmed success
-> local teardown. Today's delete path destroys the identity first, which is
exactly backwards for this feature; resequencing that path is the core
engineering work on the client side.

Two client-side corollaries:

- Confirmation semantics: the backend's deletion barrier returns a terminal
  identity-deleted response at token mint for a deleted identity. That
  response, and only that response, confirms a deletion whose outcome was
  ambiguous. A generic 401 or SIWE failure can mean an invalid nonce, a
  signature problem, or a service outage, and must leave the flow in its
  ambiguous state with keys intact.
- Auto-reauth suspension: the API client's automatic re-authentication on
  401 must be disabled for the duration of the deletion flow (and for any
  background work that could run during it). An automatic re-auth is exactly
  the request pattern that would recreate the account absent the barrier,
  and even with the barrier it turns background noise into barrier probes.

## The deletion state machine

The flow persists a durable deletion record before sending the first backend
request, and every subsequent step is a transition on that record. Without
it, there is an unrecoverable window: backend commits, the app receives
success, and is killed before writing any local evidence; on relaunch the
client would have no idea a deletion happened.

Phases, at minimum:

- `requested(operationId)`: written before the request. The operation id is
  client-generated and sent with the request, so an ambiguous outcome can be
  resolved against the backend's deletion record instead of guessed.
- `backendConfirmed`: written on receipt of success (or on a barrier
  terminal response during recovery).
- `localWipePending`: local teardown in progress, driven by the wipe
  manifest.
- `completed`: record cleared as the final act of the wipe.

Recovery on launch must distinguish four situations:

- No record: no deletion was in flight; normal startup.
- `requested`, outcome unknown: keys still exist. Retry the request while a
  token is mintable; if the mint returns the barrier's terminal response,
  promote to `backendConfirmed`. Any other failure keeps the record in
  `requested` with keys intact for a later retry.
- `backendConfirmed` or `localWipePending`: resume the wipe from the
  manifest; no backend auth is needed or possible.
- Barrier terminal response seen outside any deletion flow (for example a
  paired device discovering the account is gone): surface an explicit
  account-deleted state; never auto-provision a replacement account without
  user intent.

The record must be durable across crashes but must not itself survive the
completed wipe (completion clears it). It carries the non-secret identifiers
recovery needs to finish the job: the wipe-manifest version, the inbox id,
and the identifiers of keychain slots to clear, including the synced-backup
slot, which can otherwise be orphaned when the primary identity slot is
unreadable.

Startup observers are part of this contract: the app normally auto-creates
an XMTP identity when the keychain is empty. While a deletion record is in
any non-completed phase, identity auto-provisioning must be held off, so a
half-finished wipe does not race a fresh identity into existence.

## UX flow

1. Entry point: the existing delete row in app settings, relabeled "Delete my
   account" (accessibility label, hint, and identifier updated to match).
2. Confirmation: an explicit, destructive-styled confirmation. The copy must
   distinguish, honestly: the backend account and app-managed data (deleted;
   external copies purged within the backend's published window); financial
   and audit records retained for a stated period (see the backend plan's
   retention regime); uploaded attachments, if the retain-as-message-content
   decision goes that way; XMTP messages and protocol metadata already on
   the network and on other people's devices (not deletable); continuing
   group membership or peer-visible profile state, per the XMTP lifecycle
   decision; other devices and installations; and the App Store
   subscription (not cancelled).
3. Subscription disclosure: shown universally, not only when the client
   believes a subscription is active, because cached StoreKit state can be
   stale or unavailable. Concise "deleting your account does not cancel any
   App Store subscription" copy always; the manage-subscriptions link
   whenever the system surface is available. The user can proceed without
   cancelling; the point is informed consent, not a gate.
4. Progress: the deletion runs with clear progress feedback, network step
   first, local wipe second.
5. Completion: the app lands in a state equivalent to a first install. Since
   the app auto-provisions an identity on an empty keychain, "equivalent to
   first install" is the definition of done, not "durably identity-less";
   what matters is that provisioning happens only after the deletion record
   reaches `completed`, and that the screen the user lands on is the normal
   first-launch experience.

Decision point: whether to also keep a separate "Reset local data" action
with today's semantics (wipe and re-provision a fresh inbox). The rename must
not silently repurpose a flow some users rely on as a recoverable
troubleshooting step into an irreversible account deletion; either keep both
actions with honest names or consciously drop the reset.

## XMTP lifecycle

Backend deletion says nothing about the XMTP layer, and the two must not be
conflated: unregistering from the notification server is not XMTP
installation revocation, and without explicit protocol work the inbox
remains an MLS member of its groups, peers continue to see the member and
its profile, and other installations of the inbox can continue reading and
sending. The client already has the APIs to enumerate and revoke the inbox's
installations, so this is a set of product decisions, not a capability gap:

- Installation revocation: which installations are revoked, and is the
  deleting installation itself revoked last? Revoking all installations ends
  the inbox's ability to send or receive anywhere. Not revoking leaves
  paired devices fully functional at the XMTP layer even though their
  backend access is gone.
- Group membership: are groups left before teardown? Leaving is the only way
  peers stop seeing the member. DMs and any group the protocol will not let
  the last relevant member leave cannot shed the inbox; whatever remains
  must be acknowledged in the confirmation copy rather than papered over.
- Peer observability: peers are never notified that an account was deleted.
  Decide what they should observe (member left the group, member goes
  silent, profile stops resolving) and write the copy accordingly.
- Required or best-effort: is protocol teardown a blocking step of deletion
  or best-effort cleanup? Best-effort is the pragmatic default, but then the
  confirmation copy must not promise disappearance from conversations.
- Ordering: revoking other installations before the backend call damages the
  user's other devices if backend deletion then fails; revoking after risks
  a crash leaving the keys already gone and the revocation never done. The
  state machine must place protocol teardown explicitly (proposed: after
  `backendConfirmed`, before the keychain wipe, resumable from the record),
  and a crash during protocol teardown must resume without retaining the
  identity indefinitely.

If inbox erasure is not fully achievable at the protocol level, the plan
states that limitation plainly in the confirmation copy and in whatever
retention documentation accompanies the feature.

## Multi-device and pairing

Other paired installations of the same inbox hold the same identity key.
After deletion, what stops them is the backend's deletion barrier: their
next token mint returns the terminal identity-deleted response instead of
silently re-provisioning the account (which is what would happen today).
Their XMTP-layer capabilities persist unless the lifecycle decision above
revokes them.

The paired-device experience therefore needs explicit design: on seeing the
terminal response, a paired device should present a coherent
"this account was deleted" state (plausibly via the existing stale-device
recovery surface) with a path to wipe locally, rather than an endless auth
error or a quiet re-signup.

## Failure handling

Deletion requires network. If the backend call fails or the device is
offline, nothing local is torn down; the user sees the failure and can retry.
There is no silent fallback to a local-only wipe, because that would strand a
live server account with no keys left to authenticate its deletion.

Failure matrix, in terms of the state machine:

| State | How it happens | Recovery |
| --- | --- | --- |
| No record, local intact | Offline, server error, failure before the request was sent | Retry from settings; keys still exist |
| `requested`, outcome unknown | Network drop after sending; crash before the response was processed | On relaunch, retry with a mintable token; a barrier terminal response means the earlier attempt committed, promote to `backendConfirmed`; any other failure stays `requested`, keys intact |
| Success received, crash before the record advances | Kill between response and persistence | Covered by the same `requested` recovery: the retry or barrier probe resolves it; no state is lost because the record predates the request |
| `backendConfirmed` or `localWipePending`, wipe interrupted | Crash or kill mid-teardown | Resume the wipe from the manifest on next launch; no backend auth needed |
| Local wiped, backend never called | Must not happen | Prevented by ordering: teardown never starts before `backendConfirmed` |

The success response covers the backend's database commit and deletion
barrier; external purges (S3, Composio, notification server) drain
asynchronously within the backend's published window. The user cannot query
progress after the wipe (their credentials are gone), which is why the
confirmation copy commits to "within N hours" rather than "immediately".

## The wipe manifest

"Sweep everything identity-related" is not a spec. Local teardown runs from
a versioned, exhaustive wipe manifest, with a test per entry, because the
known inventory already exceeds what today's session teardown clears:

- Primary XMTP identity (keychain).
- The iCloud-synchronizable identity backup, which contains the private key.
  Deleting a synchronizable item can fail or propagate slowly; the wipe must
  verify, retry, and surface a persistent failure rather than assume.
- The address-scoped SIWE JWT and the cached backend account id (keychain).
  Today's session teardown does not clear these; a surviving JWT is
  especially dangerous during the ambiguous-outcome window.
- The legacy device JWT slot.
- The StoreKit `appAccountToken` and cached subscription state in
  UserDefaults.
- The analytics identity: the client identifies a stable pseudonymous person
  derived from the inbox id, which must be reset during teardown so events
  from a later identity are not attached to the deleted person.
- The app-group database, image and attachment caches, and any
  UserDefaults keys carrying inbox, device, or account identifiers.
- Pinned dependency: the in-flight reinstall-continuity work adds keychain
  slots (an installation marker and a consent backup) that intentionally
  outlive the app. When that work lands, those slots join the manifest;
  this plan and that work must be reconciled at implementation time so a
  reinstall after deletion cannot find a marker or consent backup for the
  deleted inbox and attempt ghost-installation recovery or consent restore.

Teardown must also account for concurrent writers: background tasks,
observers, or extensions attempting to rewrite identity or analytics state
after their slots were wiped. The wipe is not complete until rewrites are
blocked or provably benign.

## No-live-session path

The delete action can be reached without a ready messaging session (cold
launch, or the stale-device recovery sheet whose only exit today is the
destructive reset). The account deletion flow must be able to mint its SIWE
token from stored keys without requiring a fully started session. If the
backend adopts its proposed fresh-token requirement, the client also needs a
force-refresh path: the SIWE machinery currently reuses any cached token
with more than a minute of life left, which would fail a freshness check.

If the keys are genuinely unavailable (corrupt keychain), account deletion
is impossible from this device; the flow should say so honestly rather than
degrade into a local-only wipe that pretends to be a deletion. What to offer
that user (support contact, local-reset-only with explicit warning) is an
open question.

## Technical shape (altitude only)

- A deletion call added to the backend API client surface, behind the usual
  protocol wrapper so it can be mocked, carrying the operation id.
- The durable deletion record and its launch-time recovery, integrated with
  session startup so auto-provisioning is held while a record is active.
- Auto-reauth suspension scoped to the deletion flow.
- The session delete path resequenced: backend delete, then protocol
  teardown per the XMTP lifecycle decisions, then the manifest-driven local
  wipe, with the record advanced at each phase.
- `AuthServiceProtocol.deleteAccount(with:)` either becomes the real seam for
  this call or is removed; no dangling stub remains.
- Settings view and view model renames, the universal subscription
  disclosure, and the expanded confirmation copy.

## Test plan

- Unit: state machine transitions and launch recovery for every phase;
  ordering (backend before teardown, teardown never starts on failure);
  barrier terminal response handled as confirmation only inside a pending
  deletion; generic 401 never treated as confirmation; auto-reauth verified
  suspended during the flow; wipe-manifest execution with a test per entry.
- Integration (local backend): full delete round-trip; retry after simulated
  response loss resolving via the barrier probe; token mint after deletion
  returning the terminal response without recreating the account.
- Crash and race oriented: kill immediately before the request, after the
  backend commit but before the response, after the response but before the
  record advances, and between every wipe phase; JWT expiry immediately
  before an ambiguous retry; paired-device SIWE attempts before and after
  deletion; a background task attempting an authenticated request (and thus
  a re-auth) mid-flow; iCloud-synchronizable item deletion failure and
  delayed propagation.
- Reinstall: after account deletion, a fresh install is indistinguishable
  from a first install: no keychain residue from any manifest entry, no
  analytics continuity, first-launch onboarding, and no ghost-installation
  or consent-restore behavior once the reinstall-continuity slots exist.
- QA scenarios: delete with an active subscription (universal disclosure
  shown, manage link works); delete while offline (fails cleanly, nothing
  wiped, retry succeeds); kill the app mid-teardown (next launch completes
  the wipe); paired second device lands in the account-deleted state, not a
  silent re-signup.

## Open Questions

- [ ] Keep a separate "Reset local data" action alongside "Delete my
      account", or single action only?
- [ ] XMTP lifecycle decisions: which installations are revoked (including
      the deleting one), are groups left, what do peers observe, and is
      protocol teardown blocking or best-effort?
- [ ] Re-signup on the same device: after deletion, creating a new account
      means new identity keys (the barrier bars the old ones, subject to the
      backend's permanence decision). Is immediate re-signup allowed,
      discouraged, or gated?
- [ ] If the backend requires fresh tokens for deletion, what is the
      force-refresh design for the SIWE token path?
- [ ] What does the flow offer when keys are unavailable and true deletion is
      impossible from this device?
- [ ] Does the App Clip need any deletion affordance, or is settings-only
      sufficient? (Expectation: settings-only; the clip has no settings
      surface.)
- [ ] Copy and design for the confirmation, disclosure, and paired-device
      account-deleted states.

## References

- Companion backend plan: convos-backend repo,
  `docs/plans/delete-my-account.md`.
- Apple App Store Review Guideline 5.1.1(v) (account deletion requirement).
- Reinstall continuity (in-flight work): installation marker and consent
  backup keychain slots, pinned as a dependency of the wipe manifest.
