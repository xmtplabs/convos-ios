# Invite Code Gating for Instant Assistant

> **Status**: Draft
> **Linear**: IOS-393
> **Created**: 2026-03-24

## Overview

The "Instant assistant" toggle in the Assistants settings screen is currently available to all users. This feature gates that toggle behind a one-time invite code. The first time a user tries to enable "Instant assistant", they are prompted to enter a code. Once a valid code is redeemed, the feature is permanently unlocked app-wide for that installation — not per-conversation.

Codes are generated in bulk on the Convos backend and distributed manually. Codes can be managed via a simple admin page served by the backend itself, protected by a password stored as an environment variable.

## Problem Statement

Instant assistant is a high-value, supply-constrained feature. Without access controls, any user can enable it, which could overwhelm agent capacity and make it impossible to manage rollout. A lightweight invite code system allows the team to control distribution without requiring a full gating infrastructure.

## Goals

- [ ] Gate the "Instant assistant" toggle behind a one-time invite code on first activation
- [ ] Provide a clear, low-friction code entry experience that matches the Figma design
- [ ] Permanently unlock the feature for a user once their code is successfully redeemed
- [ ] Allow code generation and monitoring via a self-contained admin page on the backend
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
- [ ] The toggle remains ON and the unlock persists across app restarts (stored locally — no server-side identity record)

**As a user whose code has already been redeemed**, I want the toggle to work without any prompts so that I am not asked for a code again.

Acceptance criteria:
- [ ] On subsequent app launches, if the local unlock state is set, the toggle reflects the current state with no code prompt
- [ ] On a fresh install, the unlock state is gone — a new code is required (no server-side lookup)

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

**Success path**: Modal dismisses, toggle switches ON. The feature is unlocked app-wide — not tied to any specific conversation.

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

The unlock state is stored **locally only** (e.g., in UserDefaults or GRDB). The backend does not record who redeemed a code — it only validates the code and marks it as used (or deletes it). No server-side identity is stored.

This means:
- On a fresh install, the unlock state is gone and a new code is required
- No cross-device sync of unlock state
- The backend cannot answer "is this user unlocked?" — the local store is the only record

### Architecture Notes

- The unlock state check belongs in a service in ConvosCore
- The modal is a new SwiftUI view in the main app target
- The code redemption API call goes through `ConvosAPIClient`
- The local unlock state is the source of truth — no backend query needed after a successful redemption
- Privacy: the backend never stores who redeemed a code

---

## Backend Feature

### Code Storage

A new database table holds invite codes. Suggested schema:

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID | Primary key |
| `code` | string | Unique, 8 uppercase letters (e.g. `XKQBWFMR`) |
| `created_at` | timestamp | When the code was generated |
| `redeemed_at` | timestamp | Null until used; set on redemption |
| `batch_label` | string | Optional label grouping codes from the same generation run |

No `redeemed_by` column — the backend does not record who redeemed a code. On redemption, the row is either deleted or its `redeemed_at` is set. Either approach is fine; marking as redeemed (rather than deleting) is preferable for auditability in the admin page.

### Code Generation

Codes are generated in bulk via the admin page. The generation interface should support:

- Specifying a count (e.g., generate 50 codes at once)
- Optionally tagging codes with a batch label for tracking distribution campaigns
- Viewing all existing codes with their redemption status (pending / redeemed) and timestamp — no identity shown

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

No idempotency guarantee — since the backend does not store who redeemed a code, it cannot detect a duplicate redemption by the same client. The client must not retry on a `200` response; it should only retry on network errors before a response is received.

### Unlock State

The backend has no record of which clients are unlocked. There is no session/profile flag to return. The local app store is the sole source of truth.

### Admin Page

Instead of an external tool like Retool, the backend serves a self-contained admin page — a single static HTML page with inline CSS/JS that calls the backend's admin API endpoints. This keeps the admin interface simple, self-contained, and dependency-free.

**Authentication**: The page is protected by a password stored in an environment variable (e.g., `ADMIN_PASSWORD`). The page shows a login form; on submit, it exchanges the password for a session token (or sends it as a Bearer token on each request). The backend validates the password against the env var.

**Admin API endpoints** (protected by the admin password, separate from the JWT-authenticated client endpoints):

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/admin/invite-codes` | GET | Serves the HTML admin page |
| `/api/admin/invite-codes` | GET | List codes (supports `?batch=`, `?status=pending\|redeemed` query filters) |
| `/api/admin/invite-codes/generate` | POST | Generate codes (`{ "count": 50, "batch_label": "launch-wave-1" }`) |

**Page features**:

1. **Login screen** — password field, submits against the env var, stores auth in memory (not persisted across page reloads for security)
2. **Generate codes** — form with count input and optional batch label field, generates codes and displays the newly created batch
3. **View/filter codes** — table of all codes showing code, status (pending/redeemed), redeemed-at timestamp, and batch label. Filterable by batch label and redemption status

No delete or invalidation UI is needed in the initial version.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| User loses network mid-redemption | Medium | Show a clear retry state; do not mark code as used until the server confirms |
| Client fails to persist unlock after a successful redemption | Low | Write local unlock state synchronously before dismissing the modal |
| Duplicate codes generated | Low | Enforce uniqueness constraint in the database |
| User installs the app on a new device | Low | Unlock state is local-only; a new code is required per install — this is intentional and privacy-preserving |

## Open Questions

- [ ] Is there a need to revoke or invalidate a code after distribution (e.g., if a code leaks publicly)?

## References

- Linear: IOS-393
- Figma: Assistants screen and code entry modal designs
- Existing agent join endpoint: `docs/plans/agent-join-endpoint.md`
- Assistant status PRD: `docs/plans/assistant-status.md`
