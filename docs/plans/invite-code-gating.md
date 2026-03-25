# Invite Code Gating for Instant Assistant

> **Status**: Draft
> **Linear**: IOS-393
> **Created**: 2026-03-24

## Overview

The "Instant assistant" toggle in the Assistants settings screen is currently available to all users. This feature gates that toggle behind a one-time invite code. The first time a user tries to enable "Instant assistant", they are prompted to enter a code. Once a valid code is redeemed, the feature is permanently unlocked for that account.

Codes are generated in bulk on the Convos backend and distributed manually. Shane manages code creation and visibility via Retool.

## Problem Statement

Instant assistant is a high-value, supply-constrained feature. Without access controls, any user can enable it, which could overwhelm agent capacity and make it impossible to manage rollout. A lightweight invite code system allows the team to control distribution without requiring a full gating infrastructure.

## Goals

- [ ] Gate the "Instant assistant" toggle behind a one-time invite code on first activation
- [ ] Provide a clear, low-friction code entry experience that matches the Figma design
- [ ] Permanently unlock the feature for a user once their code is successfully redeemed
- [ ] Allow Shane to generate and monitor codes via the existing Retool setup
- [ ] Surface clear error feedback for invalid, already-used, or malformed codes

## Non-Goals

- No "invites remaining" counter or quota concept per user
- No ability for users to share or transfer codes to others
- No expiry date on codes — codes are valid until redeemed
- No self-serve code request flow in the app
- No referral or social graph features
- Not gating any other feature — this is specifically for "Instant assistant"

---

## iOS Feature

### User Stories

**As a new user trying to enable Instant assistant for the first time**, I want to be prompted for an invite code so that I can unlock the feature and get started.

Acceptance criteria:
- [ ] The "Instant assistant" toggle is visible in the Assistants settings screen for all users
- [ ] Tapping the toggle ON for the first time (when not yet unlocked) opens the code entry modal instead of immediately toggling on
- [ ] Tapping outside the modal dismisses it without enabling the toggle
- [ ] Submitting a valid code dismisses the modal and enables the toggle
- [ ] The toggle remains ON and the unlock persists across app restarts (tied to the clientId / installation)

**As a user whose code has already been redeemed**, I want the toggle to work without any prompts so that I am not asked for a code again.

Acceptance criteria:
- [ ] On subsequent app launches, if the installation is already unlocked, the toggle reflects the current state with no code prompt
- [ ] The unlock state is tied to the clientId (XMTP installation ID) — one code unlocks one installation

**As a user who enters an incorrect or already-used code**, I want clear feedback so that I understand what went wrong.

Acceptance criteria:
- [ ] Invalid code shows an inline error message below the text field
- [ ] Already-used code shows a distinct inline error message
- [ ] The text field remains editable after an error so the user can correct their input
- [ ] The "Continue" button is disabled while a redemption request is in flight

### UX Flow

**Trigger**: The code entry modal appears when a user taps the "Instant assistant" toggle ON and the feature is not yet unlocked for their account.

**Modal content** (per Figma):
- Title: "Additional assistants"
- Body: "To invite Assistants into more convos, please enter your code below."
- Text field with placeholder: "Invite code"
- Primary button: "Continue" (blue, pill-shaped)
- No explicit dismiss button — tapping the scrim behind the modal dismisses it

**Success path**: Modal dismisses, toggle switches ON, user can now add an instant assistant to any conversation.

**Error path**: Inline error message appears beneath the text field. Modal stays open. User can correct and retry.

**Dismiss without redeeming**: Modal dismisses, toggle stays OFF.

### States

| State | Toggle | Modal |
|-------|--------|-------|
| Not yet unlocked | OFF, tappable | Hidden |
| Toggle tapped (not unlocked) | Stays OFF | Opens |
| Submitting code | Stays OFF | Continue button disabled, loading indicator |
| Code accepted | ON | Dismisses |
| Code rejected | Stays OFF | Error message shown inline |
| Already unlocked | ON/OFF, fully functional | Never shown again |

### Persistence

The unlocked state must be stored in two places:

1. **Backend**: The redeemed code is marked as used and associated with the user's wallet address / account ID. This is the source of truth. When the app starts a session, it checks whether the account is unlocked.

2. **Local cache**: The unlock state is cached locally (e.g., in UserDefaults or GRDB) to avoid a network round-trip on every app launch. The cache is populated when the API confirms a successful redemption or when the session start query returns the unlock state.

On sign-out, the local cache for the previous account is cleared. On sign-in with a previously unlocked account, the backend state is fetched and repopulates the cache.

### Architecture Notes

- The unlock state check belongs in a service in ConvosCore
- The modal is a new SwiftUI view in the main app target
- The code redemption API call goes through `ConvosAPIClient`
- The local cached unlock state is keyed per clientId (XMTP installation ID)
- Unlock is installation-scoped: a user with two devices needs two codes (confirm with team)

---

## Backend Feature

### Code Storage

A new database table holds invite codes. Suggested schema:

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID | Primary key |
| `code` | string | Unique, human-readable (e.g. `WXYZ-1234`) |
| `created_at` | timestamp | When the code was generated |
| `redeemed_at` | timestamp | Null until used |
| `redeemed_by` | string | clientId (XMTP installation ID) of the redeemer, null until used |
| `created_by` | string | Shane's identifier or a batch label, for traceability |
| `batch_label` | string | Optional label grouping codes from the same generation run |

Codes are unique. A code cannot be redeemed more than once. The `redeemed_by` field is the authoritative record of who unlocked the feature.

### Code Generation

Shane generates codes in bulk via Retool. The generation interface should support:

- Specifying a count (e.g., generate 50 codes at once)
- Optionally tagging codes with a batch label for tracking distribution campaigns
- Viewing all existing codes with their redemption status (pending / redeemed, redeemed by whom, at what time)

Code format: 8 uppercase random letters, e.g. `XKQBWFMR`. Exclude visually ambiguous characters (`O`, `I`). No hyphens or segments.

### Redemption API

**Endpoint**: `POST /api/v2/invite-codes/redeem`

**Authentication**: Requires a valid JWT (`X-Convos-AuthToken` header), same as other authenticated endpoints.

**Request body**:
```json
{ "code": "XKQBWFMR" }
```

**Success response** (`200`):
```json
{ "success": true }
```

**Error responses**:

| HTTP status | Error code | Meaning |
|-------------|------------|---------|
| 404 | `CODE_NOT_FOUND` | No code exists with that value |
| 409 | `CODE_ALREADY_REDEEMED` | Code exists but has already been used |
| 422 | `CODE_INVALID_FORMAT` | Malformed code string (before DB lookup) |
| 401 | — | Invalid or missing JWT |

The endpoint must be idempotent for the same user: if the authenticated user has already redeemed any code, return a success response (do not error). This prevents double-redemption issues if a request is retried or if the client and server get out of sync.

### Account Unlock State

The backend must track whether a given installation has the feature unlocked. This is derived from the `invite_codes` table (any row where `redeemed_by` matches the requesting clientId).

**Session/profile endpoint**: The existing session or profile endpoint that the iOS app calls on startup should include the unlock state in its response, so the app can hydrate its local cache without an extra round-trip.

Suggested addition to the existing profile/session response:
```json
{
  "instantAssistantUnlocked": true
}
```

### Retool Integration

The Retool setup already exists for other admin operations. What Shane needs:

1. **Generate codes** — form with a count input and optional batch label, calls an internal API to bulk-insert codes
2. **View codes** — table showing all codes, their status (pending / redeemed), redeemed-by wallet, redeemed-at timestamp, and batch label
3. **Filter / search** — filter by batch label or redemption status

No delete or invalidation UI is needed in the initial version (codes that are not yet redeemed are valid indefinitely, unless the team decides to add expiry later).

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| User loses network mid-redemption | Medium | Show a clear retry state; do not mark code as used until the server confirms |
| Client caches "not unlocked" after a successful redemption | Low | On redemption success, immediately update local cache; also re-fetch on next session start |
| Shane generates duplicate codes | Low | Enforce uniqueness constraint in the database |
| User installs the app on a new device | Low | Each installation requires its own code; this is intentional (installation-scoped unlock) |

## Open Questions

- [ ] Confirm: unlock is installation-scoped (clientId), meaning a user with two devices needs two codes — is this intended?
- [ ] Is there a need to revoke or invalidate a code after distribution (e.g., if a code leaks publicly)?

## References

- Linear: IOS-393
- Figma: Assistants screen and code entry modal designs
- Existing agent join endpoint: `docs/plans/agent-join-endpoint.md`
- Assistant status PRD: `docs/plans/assistant-status.md`
