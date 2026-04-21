# Single-Inbox Identity Refactor

> **Status**: Draft
> **Date**: 2026-04-16
> **Related ADRs**: Supersedes ADR 002, substantially modifies ADR 003, 004, and 005
> **Delivery**: Single long-running PR with logical checkpoint commits
>
> **Scope change (2026-04-16, after C7):** the "truly global profile" strand of this plan was dropped. We are keeping **per-conversation profiles** (the existing `DBMemberProfile` model) for the local user, same as today. C8 is reduced to a schema cleanup that removes the unused `DBMyProfile` and `DBProfileBroadcastQueue` tables that were added speculatively in C2. Quickname storage stays in UserDefaults. References below to "truly global profile", "`DBMyProfile`", "`DBProfileBroadcastQueue`", the "broadcast worker", and the global-profile sections of the Summary / What Changes / Architecture Overview blocks are historical context only — see the updated C8 entry for the final design. The rest of the plan (single inbox, keychain singleton, device sync, push routing collapse, invite flow, UI rewire, App Clip bootstrap, test cleanup) is unchanged.

## Summary

Remove the per-conversation identity model and replace it with a standard single-inbox-per-user XMTP architecture. Each user will have one XMTP inbox, one pair of cryptographic keys, and one local XMTP database. Per-conversation display profiles are retained (both for other members, as before, and now also for the local user — the scope-change note above explains why). This is a full rewrite of the identity layer with **no data-migration path**: existing installs lose all conversations and identities on upgrade.

## Motivation

The per-conversation identity model (ADR 002) provides strong privacy by design but carries significant ongoing complexity:

- Sophisticated lifecycle management (max-20 awake inboxes, LRU eviction, sleep/wake transitions)
- A pre-creation cache to hide the 1–3s latency of creating new inboxes
- Multiple XMTP databases, gRPC streams, keychain entries, and state machines per user
- Per-conversation profile system with a Quickname UX preset to approximate a single identity
- `clientId` invariant enforcement, orphaned-identity cleanup, stale pending-invite sweeping
- A large test surface dominated by multi-inbox coordination scenarios

The simpler, conventional model lets us delete entire subsystems while still providing meaningful privacy through XMTP's E2E encryption and our existing `clientId` indirection for push routing.

### Privacy properties we keep

- End-to-end message encryption (native to XMTP)
- Backend sees only a random `clientId`, never the `inboxId`
- Per-conversation display profiles for **other members** (they continue to publish independent profiles per conversation, as today)

### Privacy properties we lose

- Cross-conversation identity isolation — one inbox ID spans all conversations
- Cryptographic finality on Explode — key destruction is no longer an option because the same keys secure every conversation
- Compromise isolation — compromising one conversation means compromising all

## Non-Goals

- Backwards compatibility with existing installs
- Multi-device UX in this refactor (pairing screens, recovery phrases, installation management) — deferred
- Replacing our custom `ProfileUpdate` codec with native XMTP profiles — pending in the protocol; we keep our codec as the interim mechanism

## Documentation Maintenance Policy

ADRs and QA tests are **updated in the same checkpoint commit that introduces the code change** — not deferred to a final docs sweep. Two reasons:

1. **QA must keep pace with code.** Another agent will run QA tests against the branch while the refactor is in progress. Stale tests (e.g., looking for the Quickname pill when Quickname has been removed) will produce false failures and obscure real regressions.
2. **ADRs must reflect intent when code lands, not weeks later.** Reviewers of checkpoint commits need current architectural context.

Every checkpoint in the plan below lists its required **ADR touches** and **QA touches**. If a checkpoint does not list one, that checkpoint does not need it.

## Parallel Validation Agents

Five teammate agents run alongside the implementation work using Claude Code's [Agent Teams](https://code.claude.com/docs/en/agent-teams) feature. They cover five axes: user-facing behavior (QA), code correctness (Tests), code quality & architecture (Review), privacy & crypto boundaries (Security), and documentation currency (Docs).

All teammates share the `single-inbox-refactor` branch and coordinate through the shared task list and mailbox; the lead session orchestrates. Heavy validation paired with a small implementation footprint is deliberate — it minimizes file conflicts on the shared branch while maximizing the probability that regressions, architectural drift, privacy mistakes, or doc rot are caught in the checkpoint they're introduced in.

### QA Agent (simulator E2E)
- Runs the structured tests in `qa/tests/structured/*.yaml` against the current branch's simulator, using `qa/RULES.md` and CXDB (`qa/cxdb/qa.sqlite`) for state.
- Verifies every user-visible flow after each checkpoint.
- Files bugs and accessibility improvements into CXDB; the implementation agent folds fixes in.

### Test Agent (unit + integration)
- Runs the Swift test suite: `./dev/up && swift test --package-path ConvosCore && ./dev/down`.
- Focuses on the Docker-backed integration tests that exercise real XMTP flows against a local node. These are currently the flakiest surface in the repo, largely because multi-inbox coordination, LRU eviction, and pre-creation timing races produce intermittent failures that are hard to reproduce.
- **Secondary goal**: use the simplification to make the integration suite reliable. Each checkpoint that removes a source of flake (e.g., C4 deletes `InboxLifecycleManager`) is an opportunity to de-flake tests. Record before/after flake rates in a dedicated file (`docs/plans/integration-test-stabilization-log.md`) so we have evidence the architecture change delivers the reliability dividend.
- Reports regressions immediately so the implementation agent can address them in the same checkpoint.

### Code Review Agent (architecture + quality)
- Reviews every diff merged to the integration branch `single-inbox-refactor` after each checkpoint lands.
- Uses the `code-reviewer` subagent under the hood; supplements with `swift-architect` when reviewing structural changes (e.g., C4 deletions, C5 state machine).
- Looks for: architectural drift from the plan, anti-patterns, bugs, security concerns, missing tests, CLAUDE.md/SwiftLint violations, gratuitous complexity, dead code, and improvements the implementing teammate may have missed.
- Does **not** push code. Files findings back to the orchestrator (or directly to the owning teammate) as annotated review notes. If the finding is a bug, it becomes a fix-up commit on the owning teammate's branch; if it's architectural, it may prompt a plan revision.
- Also reviews the plan itself periodically — if decisions drift during implementation, the plan should be updated rather than letting it rot.

### Security Review Agent (privacy + crypto boundary)
- Focused review of the checkpoints that touch identity, crypto, and privacy boundaries: C3 (keychain attributes, iCloud sync, app-group access), C6 (XMTP device sync enablement), C7 (push payload and backend exposure), C9 (explode flow — no ciphertext leaks, no unintended retention), C10 (invite sender-privacy regressions), C12 (App Clip keychain handoff).
- Verifies that the "privacy properties we keep" section of this plan is actually preserved in code, and that "privacy properties we lose" doesn't quietly grow.
- Does **not** push code. Findings are escalated as blockers when appropriate — a privacy regression is a "must-fix before checkpoint merges" issue, not a deferrable note.

### Docs Maintainer Agent (ADRs + plan + stabilization log)
- Ongoing responsibility for keeping `docs/` in sync with the code.
- After each checkpoint merges, verifies the ADR touches listed in the checkpoint actually landed; if any were forgotten, opens a small doc-only PR to `single-inbox-refactor` with the missing amendments.
- Drafts `docs/plans/invite-system-single-inbox.md` in collaboration with the implementation teammate **before** C10 lands.
- Maintains the narrative portions of `docs/plans/integration-test-stabilization-log.md` (raw numbers come from the Test Agent; Docs provides per-checkpoint commentary and the final summary).
- Drafts the new "ADR 011 – Single-Inbox Identity Model" at C14 as the canonical replacement for ADR 002.
- Drafts the PR description and release notes at closeout.
- Watches for drift: if implementation diverges from the plan, flags it and proposes a plan edit in a doc-only commit.

Every checkpoint below lists a **Tests** line specifying what the Test Agent should verify on that commit. If "Tests" says "must pass," the checkpoint is not considered done until the Test Agent reports green.

## Teammate Split

This refactor is executed by **2 implementation teammates and 5 continuous validators**, spawned and orchestrated via Claude Code's Agent Teams feature. The lead session (the one that creates the team) coordinates work via the shared task list and mailbox; teammates message each other directly. All teammates share the `single-inbox-refactor` branch — file-level conflict avoidance is enforced by the Overlap Resolution Rules below, not by per-teammate branches.

The implementation side is deliberately thin — a single sequential "core" track plus a late-stage UI track — so that `SessionManager`, `KeychainIdentityStore`, `MyProfileWriter`, and every other hotly-contested file has exactly one owner at a time and no concurrent-edit conflicts arise.

### Implementation teammates

| Name | Checkpoints | Start condition | Notes |
|------|-------------|-----------------|-------|
| `single-inbox-core` | C1 → C2 → C3 → C4 → C5 → C6 → C7 → C8 → C9 → C10 → C12 (strictly in order) | Immediately | Owns every file the refactor substantively rewrites. Each checkpoint is merged into `single-inbox-refactor` before the next begins, and the checkpoint is only considered done once the five validators report green. |
| `single-inbox-ui` | C11, plus the implementation side of C13 (re-enabling tests disabled in C2) | After C9 merges into `single-inbox-refactor` | Rewires ViewModels and Quickname view layer against the new GRDB-backed storage. Does **not** edit `SessionManager`, `SessionStateMachine`, `KeychainIdentityStore`, or `MyProfileWriter` — coordinates with `core` through findings if changes are needed there. |

### Validation teammates (continuous)

| Name | Role | Start condition |
|------|------|-----------------|
| `single-inbox-qa` | Simulator E2E via `qa/tests/structured/*.yaml` + CXDB | Immediately (establishes behavior baseline) |
| `single-inbox-tests` | `./dev/up && swift test && ./dev/down`; owns raw numbers in `docs/plans/integration-test-stabilization-log.md`; drives C13 flake fixes | Immediately (records baseline flake rate) |
| `single-inbox-review` | Architectural and code-quality review of each merged checkpoint (`code-reviewer` + `swift-architect` subagents) | Immediately |
| `single-inbox-security` | Privacy/crypto boundary review (keychain attributes, iCloud sync, XMTP device sync, push payload, explode leaks, invite privacy, App Clip handoff) | Immediately; spikes activity at C3, C6, C7, C9, C10, C12 |
| `single-inbox-docs` | ADR amendments, plan drift, stabilization-log narrative, invite-system follow-up plan, ADR 011, release notes | Immediately |

### Dependency graph

```
                    C1→C2→C3→C4→C5→C6→C7→C8→C9→C10→C12
   core   ──────────────────────────────────────────────►
                                             │
   ui                                        └── C11, C13-impl ───►

   (qa + tests + review + security + docs run continuously from day one,
    validating each checkpoint as it merges into single-inbox-refactor)
```

### Branching strategy

- **Single shared branch**: `single-inbox-refactor`, off `dev`. All teammates work on this branch directly via Claude Code's Agent Teams feature — no per-teammate worktrees or sub-branches.
- The lead session spawns teammates and they coordinate through the shared task list and mailbox. Each commits directly to `single-inbox-refactor`.
- File-level conflict avoidance follows the Overlap Resolution Rules below — `core` owns architecture files, `ui` owns view files, validators are read-only (except `docs` which only writes documentation files).
- **Final PR**: `single-inbox-refactor` → `dev`.

### Overlap resolution rules

With only one implementation teammate touching architecture at a time, overlaps collapse to a small list:

- **`core` ↔ `ui`**: `ui` must not edit files owned by `core` (see its row above). If `ui` finds a bug in those files, it files a finding and `core` (or the Review agent, or the orchestrator) routes the fix.
- **`core` ↔ `docs`**: ADR amendments land in the same commit as code **by default**. If `docs` notices a missed amendment post-merge, it lands a small doc-only PR rather than asking `core` to rewrite history.
- **`core` ↔ `security`**: Security findings in C3/C6/C7/C9/C10/C12 can block a checkpoint merge. `core` is expected to wait for the security sign-off on those checkpoints specifically.
- **Plan document**: edited by whoever discovers the drift — most often `docs`, sometimes `review`.

## Guiding Decisions

| Area | Decision |
|------|----------|
| Onboarding | Silent auto-create of the XMTP **identity** on first launch (no user prompt). The existing **Quickname setup flow** on first-conversation creation is preserved. |
| Quickname storage | Stays in UserDefaults (per-conversation-flavor). C8 originally planned a `DBMyProfile` table + a broadcast worker; that was rescoped to table drops only, so Quickname is unchanged from today. |
| Key storage | Keychain with iCloud Keychain sync enabled by default |
| Multi-device | XMTP Device Sync enabled by default; no UX/recovery in this phase |
| Profile scope | Per-conversation (Quickname), same as today. The refactor does not globalize profiles — only identity. |
| ConvosProfiles package | Folded back into ConvosCore |
| Explode mechanic | Remove all members → creator leaves; no private-key destruction |
| ClientId | Kept as a single per-user UUID indirection for backend privacy |
| Database | Drop entire schema; start fresh from migration-0 |
| Invites | Simplified in this phase to minimum viable; detailed redesign in a dedicated follow-up plan |
| App Clips | Creates identity in shared app-group keychain; main app inherits seamlessly |
| Delivery | One long-running PR with logical commits |
| Feature scope | Preserve all non-identity features; only update those that touch identity |

## High-Level Architecture

### Before

```
User
 └─ N XMTP Inboxes (one per conversation)
      ├─ N Keychain entries
      ├─ N XMTP local databases
      ├─ N gRPC streams
      ├─ N Key pairs (secp256k1 + 256-bit db key)
      └─ N Profiles (one per conversation)

InboxLifecycleManager: max 20 awake, LRU eviction, pre-creation cache
SessionManager: clientId → MessagingService map (many)
```

### After

```
User
 └─ 1 XMTP Inbox
      ├─ 1 Keychain entry (iCloud-synced)
      ├─ 1 XMTP local database
      ├─ 1 gRPC stream
      ├─ 1 Key pair
      └─ Per-conversation Quickname / DBMemberProfile (unchanged from today)

Session: single session, single SessionStateMachine
MessagingService: single instance
```

### Data-flow simplifications

- **Create conversation**: use existing client → create group. No inbox pre-creation, no LRU, no cascading state machines.
- **Join conversation**: use existing client → join group.
- **Update profile**: same per-conversation `ProfileUpdate` message path as today (scope change dropped the global-profile strand; see line 8).
- **Receive push**: single inbox decrypts; no `clientId` → inbox routing.
- **Explode**: creator sends `ExplodeSettings`, removes all members, then leaves. Recipients delete the conversation locally; no identity is destroyed.

## Changes by Domain

### 1. Identity & Keychain

**Remove**
- `UnusedInboxCache` (entire file + tests)
- ClientId generation coupled to inbox creation
- Multi-identity lookups keyed by `clientId`
- `KeychainIdentityStore.identity(forClientId:)` as a polymorphic accessor (becomes a singleton accessor)

**Modify**
- `KeychainIdentityStore`: single `KeychainIdentity` under a fixed key.
  - `kSecAttrAccessible`: change from `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to `kSecAttrAccessibleAfterFirstUnlock`
  - `kSecAttrSynchronizable`: `true` (iCloud Keychain sync)
  - App-group access preserved so NSE and App Clips can still read it.
- `ClientId`: kept as a single per-user UUID, generated once during onboarding, persisted alongside the identity.

**Add**
- First-launch bootstrap in the app entry point: check keychain → create identity silently if absent.

### 2. Session Management

**Remove / collapse**
- `InboxLifecycleManager` — entire file
- Awake/sleeping tracking, LRU eviction, rebalance logic
- Pending-invite protection logic
- `SleepingInboxMessageChecker`
- `UnusedInboxCache`
- Per-inbox `MessagingService` mapping
- `WakeReason` enum
- Inbox eviction and stale-identity cleanup code paths

**Simplify**
- `SessionManager` → owns one `MessagingService`. Responsibilities shrink to: authenticate once, register device with backend, observe app foreground/background, dispatch push notification events to the single messaging service.
- `InboxStateMachine` → rename to `SessionStateMachine`. States: `idle` → `authorizing` → `ready` → `backgrounded` (⇄ `ready`). Remove `deleting`/`stopping` except for user-initiated full reset.
- `ConversationStateMachine` → keep for create/join flows, but without the coordination dance with `InboxStateMachine`.

### 3. Database Schema

**Strategy**: drop the entire existing schema. Start from a fresh migration-0. On upgrade from any prior version, wipe the database directory and recreate.

**Tables modified**
- `DBInbox` → singleton table (one row). Columns: `inboxId`, `clientId`, `createdAt`. Enforce singleton with a uniqueness constraint on a fixed key column.
- `DBConversation` → drop `inboxId` and `clientId` columns; drop their composite unique key.
- `DBMember` → keep; `inboxId` is the canonical XMTP member identifier (including other users).
- `DBMemberProfile` → keep composite PK `(conversationId, inboxId)` for every member's profile, including the local user's — the scope-change note at line 8 preserved per-conversation profiles across the board.
- `DBMessage`, `DBConversationMember`, `ConversationLocalState`, `DBInvite` → drop `clientId` columns where present.
- `InboxActivityRepository` and backing tables → delete.
- `PendingInviteRepository` → simplify (no `clientId` scoping).

**Tables added** — none. C2 originally added `DBMyProfile` and
`DBProfileBroadcastQueue` in anticipation of a global-profile design;
the scope change (line 8) dropped that design, and C8 reduced to a
schema cleanup that drops the unused tables. No tables added in the
final landing.

### 4. Profile System

Per-conversation profiles are kept — the scope change dropped the
global-profile strand (see line 8). What C1's `ConvosProfiles` →
`ConvosCore` fold actually changes is module placement, not semantics.

**Fold**
- `ConvosProfiles` → `ConvosCore/Sources/ConvosCore/Profiles/`.
  `ProfileUpdateCodec`, `ProfileSnapshotCodec`, `ProfileSnapshotBuilder`,
  `ProfileMessageHelpers`, protobuf schema, file names and contents all
  unchanged. `MyProfileWriter` continues to publish per-conversation
  `ProfileUpdate` messages as it does today.

**Preserve (unchanged from today)**
- Per-conversation profile storage (`DBMemberProfile`, keyed on
  `(conversationId, inboxId)`) for both the local user and other
  members.
- `ProfileUpdate` / `ProfileSnapshot` custom content types.
- Encrypted avatar storage (AES-256-GCM, ADR 009).
- Quickname UX surface: setup prompt, per-conversation edit, App
  Settings edit screen. Storage remains in UserDefaults.

**What doesn't land this refactor**
- Global-profile editor, `DBMyProfile`, `DBProfileBroadcastQueue`,
  `ProfileBroadcastWorker`, and the "edit once, fan out everywhere"
  UX. Tracked for a future cycle if/when the product direction
  re-opens it.

### 5. Push Notifications

**Simplify**
- `PushNotificationPayload.clientId` becomes a validation check — if it does not match the single user's `clientId`, drop the notification as stale
- `subscribeToTopics`, `unsubscribeFromTopics`, `unregisterInstallation` API signatures unchanged; `clientId` is always the single user's
- `CachedPushNotificationHandler`: remove the `clientId` → inbox map (single inbox, single handler)
- NSE: same app-group keychain read, now resolves to the single identity

### 6. Explode Feature

**New mechanic**
1. Creator initiates explode
2. Send `ExplodeSettings` message to the group (unchanged codec)
3. Update local `DBConversation.expiresAt`
4. Creator calls `xmtpGroup.removeMembers(allOtherMembers)`
5. Creator calls `xmtpGroup.leave()` (or sets consent `.denied` then leaves)
6. Delete local conversation data (messages, members, metadata, profile records, invites for this conversation)
7. **Do not delete the keychain identity**

**Receiver**
- On `ExplodeSettings` message: schedule local cleanup per `expiresAt`
- On "removed from group" XMTP stream event: delete conversation locally regardless of `ExplodeSettings`

**Files affected**
- `ExpiredConversationsWorker`: replace the `leftConversationNotification` → inbox-deletion path with a conversation-only deletion path
- `ConversationExplosionWriter`: updated cleanup logic
- `InboxStateMachine.handleDelete()` (or its successor): no longer triggered by explode; only by a deliberate logout/reset

### 7. Invites (Minimum Viable in This Phase)

**Shipped in this refactor**
- Accept-invite flow no longer creates a per-conversation inbox; it simply adds the user's single inbox to the existing group
- Invite token generation and validation remain in place as-is where possible
- `JoinRequest` content type continues to work; payload carries the existing per-conversation profile (see scope-change note at line 8 — global profile was dropped)
- Pending-invite storage simplified (`clientId` scoping removed)

**Deferred to a dedicated follow-up plan** (`docs/plans/invite-system-single-inbox.md`)
- Full redesign of sender-side invite privacy (previously implicit via per-conversation inboxes)
- Invite tag storage reconsideration (currently in appData)
- Notification routing for pending invites in the single-inbox world
- End-to-end privacy model documentation post-refactor

The follow-up plan must land **before** we start substantive invite code changes beyond the minimum shim described here.

### 8. XMTP Client Configuration

**Change**
- Enable XMTP Device Sync in `ClientOptions`
  - Configure `historySyncUrl` per environment
  - Persistent `dbEncryptionKey` unchanged in shape
- Register custom codecs once, at session start, on the single client: `ProfileUpdate`, `ProfileSnapshot`, `ExplodeSettings`, `JoinRequest`, `TypingIndicator`, `AssistantJoinRequest`, plus standard text / reply / reaction / attachment / remote attachment / group updated
- `XMTPAPIOptionsBuilder` updated accordingly

### 9. App Clips

**New flow**
- App Clip target creates and stores the single identity in the shared app-group keychain (`group.convos.keychain`), reusing `ConvosCore` identity bootstrap
- On first launch of the main app after App Clip usage, the identity is already present → no onboarding animation
- If the user installs the main app without using the App Clip first, the main app creates the identity itself

**Files affected**
- App Clip target entry point: call identity bootstrap
- Main app onboarding check: short-circuit when an app-group identity exists

### 10. UI / ViewModels

**Remove**
- Any "inbox switcher" UI (if present in debug/settings)
- "Which inbox?" pickers anywhere in the app

**Preserve**
- Quickname settings screens and flows (semantics change, UI kept)
- Per-conversation Quickname edit entry point (edits stay scoped to that conversation's `DBMemberProfile`; an opt-in toggle also writes the Quickname template in UserDefaults so future new conversations pick it up — see the scope-change note at line 8, nothing propagates globally to existing conversations)
- First-conversation Quickname setup prompt

**Modify**
- `ConversationViewModel`: drop `clientId`/`inboxId` tracking; drop the `leftConversationNotification` → inbox-deletion observer
- `NewConversationViewModel`: drop the inbox-creation branch; talks directly to the single messaging service
- `MyProfileViewModel`: unchanged (scope change kept per-conversation profiles and the existing UserDefaults-backed Quickname; the global-profile editor + broadcast-progress indicator are not part of this refactor — see line 8)
- `ConversationsViewModel`: no cross-inbox filtering
- `AppSettingsViewModel`: add iCloud Keychain sync status and device-sync status indicators

## Removed Systems Inventory

Files deleted entirely (non-exhaustive):
- `ConvosCore/Sources/ConvosCore/Inboxes/InboxLifecycleManager.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/SleepingInboxMessageChecker.swift`
- `ConvosCore/Sources/ConvosCore/Messaging/UnusedInboxCache.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/InboxActivityRepository.swift`
- Associated test files (see Test Strategy)

Features deleted:
- LRU eviction, sleep/wake, pre-creation cache
- `ClientId` invariant-mismatch error surface (trivial with singleton)

Files kept unchanged (scope change kept per-conversation profiles and UserDefaults-backed Quickname; see line 8):
- `Convos/Profile/QuicknameSettings.swift`, `QuicknameSettingsViewModel.swift`
- `MyProfileWriter`

Conceptually retired but kept as simplified stubs:
- `DBInbox` (singleton row)
- `ClientId` (single UUID)

## Test Strategy

The Test Agent runs continuously (see **Parallel Validation Agents** above). What follows is the strategy it executes against.

**Delete or fully rewrite**
- `InboxLifecycleManagerTests`, `SessionManagerTests`, `SleepingInboxMessageCheckerTests`, `UnusedInboxCacheTests`, `TripleInboxAuthorizationTests` → delete
- `InboxStateMachineTests` → replace with `SessionStateMachineTests` covering the reduced state graph
- Multi-inbox fixtures in other tests → simplify to single-inbox

**Add**
- `AppClipIdentityHandoffTests`: identity created in App Clip, discovered by main app
- `KeychainSyncConfigTests`: smoke-test that sync attributes are set correctly (full iCloud sync is not unit-testable)
- `ExplodeRemoveAndLeaveTests`: end-to-end "remove all then creator leaves" flow, including receiver-side local cleanup

**Preserve with minor updates**
- Messaging, reactions, read receipts, replies, attachments, voice memos, videos — should pass with minimal changes
- Invite tests — flagged for the invite follow-up phase

## Checkpoint Commits Within the Long-Running PR

Each checkpoint below lists the **code** changes, the **ADR** edits that land with it, and the **QA** test edits that land with it. The branch should be QA-runnable (by the QA agent) after each checkpoint, even if some tests must be marked as skipped-pending-checkpoint-N in an upstream commit.

### C1 — Fold `ConvosProfiles` into `ConvosCore`
- **Code**: Move files to `ConvosCore/Sources/ConvosCore/Profiles/`. No behavior change.
- **ADR**: Note the package fold in ADR 005 "Related Files" section.
- **QA**: None.
- **Tests**: Full `./dev/up && swift test` must pass. Establishes the baseline flake rate for this branch — record it in the stabilization log.

### C2 — New migration-0 schema + legacy-wipe detection
- **Code**: Add new tables `DBMyProfile` and `DBProfileBroadcastQueue`; make `DBInbox` a singleton (enforce via uniqueness constraint on a fixed key column); delete `InboxActivityRepository` and its backing table; add legacy-data detection and wipe on first launch. The `inboxId`/`clientId` columns on `DBConversation`, `DBMessage`, `DBConversationMember`, and similar row tables are **left in place** — callers still depend on them and they will be dropped alongside the caller rewrites in C4.
- **ADR**: Draft amendment to ADR 002 marking it Superseded (full supersession lands at the end when the behavior is complete).
- **QA**: **Rewrite `13-migration.md`** and its structured YAML — the existing test exercises per-inbox migration; the new test verifies legacy-wipe behavior on upgrade (start from a build with prior data → install new build → conversations empty, new identity created silently, no crash). Add a note that the test is expected to fail until later checkpoints land.
- **Tests**: Migration tests updated to match the new schema. Expect broad breakage of tests that instantiate multi-inbox fixtures — mark those as `@Test(.disabled)` with a TODO referencing C13 rather than deleting them now. Full `swift test` target: schema/DB tests green; everything else at a known failure set documented in the stabilization log.

### C3 — `KeychainIdentityStore` singleton + iCloud Keychain sync
- **Code**: Change keychain access attributes, single-identity accessor, drop `identity(forClientId:)` polymorphism.
- **ADR**: Amend ADR 002 "Secure Keychain Storage" section — new attributes, iCloud sync enabled.
- **QA**: Add a new test `qa/tests/35-identity-persistence.md` (+ structured YAML) — verify identity survives app reinstall on the same simulator (approximates iCloud sync within unit-test reach). Note in the test file which assertions require real iCloud Keychain and must be run on device.
- **Tests**: Keychain tests updated; new `KeychainSyncConfigTests` asserting the sync attributes are set. All keychain-touching tests must pass.

### C4 — Delete multi-inbox infrastructure
Split into four sub-commits to keep each landing reviewable and compilable in isolation. The PR as a whole is still "C4"; the sub-labels (C4a–d) are per-commit tags.

**C4a** — Delete `InboxLifecycleManager`, `UnusedInboxCache`, `SleepingInboxMessageChecker`, `InboxActivityRepository` + their tests (`InboxLifecycleManagerTests`, `UnusedInboxCacheTests`, `SleepingInboxMessageCheckerTests`, `SleepingInboxMessageCheckerIntegrationTests`, `InboxActivityRepositoryTests`, `TripleInboxAuthorizationTests`, `ConsumeInboxOnlyTests`, `UnusedConversationConsumptionTests`, `SessionManagerTests`). Rewrite `SessionManager` as a lazy singleton around one `MessagingService`, preserving the public `SessionManagerProtocol` surface (`clientId`/`inboxId` parameters become ignored placeholders so the view-model layer compiles until C11). The `inboxId`/`clientId` SQL columns and the legacy multi-identity keychain API remain in place for the duration of C4a — callers still depend on them and they come out in C4b/C4c.

**C4b** — Retire the multi-identity keychain API. Rewrite the remaining callers (`InviteWriter`, `StreamProcessor`, `InviteJoinRequestsManager`, `InboxStateMachine`, `UnusedConversationCache`, `ConversationStateMachine`, and their tests) to use `loadSingleton` / `saveSingleton` / `deleteSingleton`. Delete the legacy per-inbox methods from `KeychainIdentityStore` + mock. Keep row-level `inboxId`/`clientId` usage alone.

**C4c** — ~~Drop `inboxId`/`clientId` columns from row tables~~ → **Deferred to C11 (see note below).**

**C4d** — Mark ADR 003 as Superseded with a pointer to this plan. Rewrite `qa/tests/15-performance.md` (and YAML): remove LRU/capacity-limit assertions; replace with single-client responsiveness assertions. Record the integration-suite flake rate after the C4a/C4b deletions in `docs/plans/integration-test-stabilization-log.md` (re-run the suite 10× — expect a dramatic drop now that multi-inbox timing is out of the picture).

#### Column-drop deferral note

The `inboxId`/`clientId` columns on `DBConversation`, `DBConversationMember`, `DBMember`, and `DBInvite` are read by the public domain model (`Conversation.inboxId`, `Conversation.clientId`) that every ViewModel in the main app layer consumes. Dropping those columns forces an atomic cascade into the ViewModel layer — which is explicitly **C11's scope**. Attempting C4c before C11 would leave the ViewModels referencing Swift properties that no longer exist; splitting the column drop from the caller rewrite would leave rows persisted with stale placeholder values.

**Decision**: merge the column drop into C11. The C11 checkpoint now covers: ViewModel `inboxId`/`clientId` tracking removal + `DBConversation`/`Conversation` domain-model property removal + the SQL schema migration + lockstep writer/repository updates. The `inbox` table itself (the one collapsed to singleton behavior in C2) can stay until the main-app rewrite lands — its columns are internal to `SessionManager`'s cleanup flows and don't cross into the ViewModels.

Net effect on C4's PR diff: C4a+C4b+C4d land under C4. The column drop arrives with C11. The Swift identifier inventory (~368 `.inboxId` / `.clientId` references across ConvosCore + Convos + ConvosAppClip + ConvosNotificationService) is unchanged until C11 kicks off.

### C5 — `SessionStateMachine` replaces `InboxStateMachine`
- **Code**: Simplified state graph; remove `deleting`/`stopping` (except for full reset).
- **ADR**: Update ADR 003 diagram reference (if still linked from the superseded notice).
- **QA**: None — internal refactor.
- **Tests**: `InboxStateMachineTests` → `SessionStateMachineTests`. All session-machine tests must pass. Verify no flakiness under `swift test --repeat-count 10` on this target.

### C6 — XMTP client config: enable device sync, register codecs
- **Code**: Enable `historySyncUrl` per environment; register custom codecs on the single client.
- **ADR**: Amend ADR 002 "XMTP Client Configuration" section — device sync enabled.
- **QA**: None directly. Flag for later: document observed behavior if a second simulator is booted with the same iCloud account (multi-device scope item, not blocking).
- **Tests**: Integration tests that hit the local XMTP node must continue to pass. If device sync changes test fixture behavior (e.g., history replay), update fixtures minimally.

### C7 — Push notification simplification + NSE
- **Code**: Collapse routing to single inbox; NSE reads the singleton keychain identity.
- **ADR**: Amend ADR 002 "Push Notification Routing" section — single clientId per user.
- **QA**: Spot-check existing push-dependent tests (`28-app-icon-badge-count.md`). Likely unaffected at the surface level; confirm during QA run.
- **Tests**: Push handler and NSE tests pass. `CachedPushNotificationHandler` tests simplified to single-inbox routing.

### C8 — Drop unused global-profile tables (scope reduced)
**Decision (2026-04-16):** the global-profile design — Quickname as a truly global identity that fans out edits across all conversations via a `ProfileBroadcastQueue` — was **dropped** in favor of keeping per-conversation profiles. The existing `DBMemberProfile` table (keyed on `(conversationId, inboxId)`) already supports per-conversation profiles without schema change. `MyProfileWriter` continues to publish per-conversation `ProfileUpdate` codec messages as it does today.

- **Code**: Delete `DBMyProfile.swift` and `DBProfileBroadcastQueue.swift` (introduced in C2 in anticipation of the global design, never populated). Add a new migration `v1-drop-global-profile-tables` on top of the v0 baseline to drop the now-unused `myProfile` and `profileBroadcastQueue` tables. No changes to `MyProfileWriter`, `ProfileCoordinator`, Quickname storage, or any QA tests.
- **ADR**: None. The per-conversation profile architecture documented in ADR 005 remains correct as-is.
- **QA**: None. `07-profile-update.md` and `14-quickname.md` keep their current semantics.
- **Tests**: None — there are no tests for the dropped types since they were never wired up.

### C9 — Explode rewrite: remove-all-then-leave
- **Code**: Creator sends `ExplodeSettings`, removes members, leaves. Receivers delete conversation locally on message or `removed` event. No keychain deletion.
- **ADR**: Amend ADR 004 "Decision" and "Deletion Mechanism" sections; preserve the historical context.
- **QA**:
  - **Rewrite `09-explode-conversation.md`** — assertions change from "keychain entry gone" to "all members removed → group empty → creator left → conversation gone locally on all devices." Add a two-simulator variant where Device B is the joiner that observes explosion from the member side.
  - **Rewrite `23-scheduled-explode.md`** accordingly.
- **Tests**: New `ExplodeRemoveAndLeaveTests` cover the end-to-end flow (creator removes members, creator leaves, receivers delete locally, no keychain touch). Old explode tests asserting keychain cleanup are deleted. `ScheduledExplosionManagerTests` updated.

### C10 — Invite shim
- **Code**: Accept-invite flow uses the single inbox; no per-conversation inbox creation. Pending invite storage drops `clientId` scoping. Invite token format unchanged for now.
- **ADR**: Add a note to ADR 001 that substantial redesign is tracked in `docs/plans/invite-system-single-inbox.md`.
- **QA**: Update `03-invite-join-deep-link.md`, `04-invite-join-paste.md`, `23-pending-invites-home-view.md`, `24-pending-invite-recovery.md`, `31-convos-button-invite.md` — most assertions should still pass; verify no "new inbox" UI indicator is expected.
- **Tests**: `PendingInviteRepositoryTests` simplified (no `clientId` scoping). Invite-flow integration tests rewritten to target single-inbox join. Expect this to de-flake tests that previously raced against inbox pre-creation during invite accept.

### C11 — UI / ViewModel updates
- **Code**: Remove inbox switcher (if any). Rewire `MyProfileViewModel`, `ConversationViewModel`, `NewConversationViewModel`, `ConversationsViewModel`, `AppSettingsViewModel` to drop `clientId`/`inboxId` tracking and talk to the single session. Quickname screens preserved unchanged — scope change kept UserDefaults-backed Quickname storage (see line 8).
- **ADR**: None.
- **QA**: Update `01-onboarding.md` minimally if needed — identity creation is silent, but the existing Quickname prompt after first-conversation creation still fires. Most of the existing script should keep passing. If specific assertions (e.g., "Quickname saved confirmation appears") still apply verbatim, leave them. Update the corresponding YAML only where the UI sequence actually changed.
- **Tests**: ViewModel tests updated for the simplified state. Build must pass. Snapshot/preview-driven tests updated only where behavior changed.

### C12 — App Clips identity bootstrap
- **Code**: App Clip entry point creates identity in shared app-group keychain; main app short-circuits onboarding when identity exists.
- **ADR**: Amend ADR 002 with an App Clip note (identity created in shared container).
- **QA**: **Add `qa/tests/37-app-clip-handoff.md`** — install App Clip, complete preview flow (creates identity), install main app, verify no onboarding and identity continuity. Mark steps that require TestFlight-style App Clip distribution as manual-only; cover what's runnable on simulator automatically.
- **Tests**: New `AppClipIdentityHandoffTests` cover the keychain-handoff code path at a unit level. End-to-end App Clip install/launch flow is covered by QA.

### C13 — Test cleanup + integration-test stabilization pass
- **Code**: Re-enable anything disabled in C2 that's now fixable. Finish deleting any stragglers from `InboxLifecycleManagerTests`, `SessionManagerTests` (or rewrite), `SleepingInboxMessageCheckerTests`, `UnusedInboxCacheTests`, `TripleInboxAuthorizationTests`. Confirm renames/additions from earlier checkpoints (`SessionStateMachineTests`, `ProfileBroadcastWorkerTests`, `AppClipIdentityHandoffTests`, `KeychainSyncConfigTests`, `ExplodeRemoveAndLeaveTests`) are in place.
- **ADR**: None.
- **QA**: None — unit/integration only.
- **Tests**: **This is the dedicated flake-fix checkpoint.** Run the integration suite 20× and drive remaining flake rate toward zero. Fixes at this point are small, targeted changes to timing, fixture setup, or XMTP sync waits — not architectural. Record the final before/after flake table in the stabilization log.

### C14 — Final ADR sweep + release notes
- **Code**: None.
- **ADR**: Final pass — confirm ADR 002 status = Superseded with full context, ADR 003 Superseded, ADRs 004/005 amendments read cleanly, new "ADR 011 – Single-Inbox Identity Model" drafted and added as the canonical replacement for ADR 002.
- **QA**: Run the full suite end-to-end; fix any drift discovered, then re-run. Produce a final CXDB report attached to the PR description.
- **Tests**: Final `./dev/up && swift test && ./dev/down` run ×3 clean. Publish the final stabilization-log table in the PR description alongside the QA report.

#### C14 release notes (for the PR description)

Copy-paste into the PR body at merge time:

```markdown
## Single-Inbox Identity Refactor

Replaces the per-conversation identity model (ADR 002) with a single
XMTP inbox per user. Canonical design: [ADR 011](docs/adr/011-single-inbox-identity-model.md).

### User-facing changes
- Existing installs lose all conversations and identities on upgrade.
  `LegacyDataWipe` runs once per schema-generation marker and reports
  nothing to the user beyond the fresh state.
- No more Quickname preset screen — users have one identity across all
  conversations by default.
- Explode now sends `ExplodeSettings`, removes every other member from
  the MLS group, and leaves. Receivers drop the conversation on the
  message or on the MLS "removed" commit, whichever arrives first.
- New device under the same Apple ID inherits the identity via iCloud
  Keychain and the group membership via XMTP device sync.

### Architecture changes
- **Deleted** (subsystems, not just files): `InboxLifecycleManager`,
  `UnusedInboxCache`, `SleepingInboxMessageChecker`,
  `InboxActivityRepository`, multi-inbox coordination in
  `SessionManager`, pre-creation cache, placeholder service path.
- **Added**: `KeychainIdentityStore.loadSync`, `SessionManager`
  one-slot lock-guarded cache, `CachedPushNotificationHandler`
  identity-keyed cache invalidation, `PushNotificationServiceFactory`
  test seam, `LegacyDataWipe` generation-gated upgrade wipe, App Clip
  identity bootstrap.
- **Wire protocol**: push-notification payload shape unchanged;
  `clientId` indirection preserved.

### Privacy changes
- **Lost**: cross-conversation identity isolation, cryptographic
  finality on explode, device-binding guarantee (`kSecAttrSynchronizable`).
- **Preserved**: backend sees only `clientId`, ciphertext stays inside
  XMTP, per-conversation display profiles for other members, NSE
  cannot decrypt for identities it was not routed to.

### Evidence
- Integration suite: 0 / 10 post-fix flake rate, plus final ×3 clean
  in C14 — see `docs/plans/integration-test-stabilization-log.md`.
- QA report: attach the CXDB report from the QA agent here at merge
  time.
- ADR changes: 002 superseded by 011; 003 superseded; 004 amended
  (C9 remove-all-then-leave); 005 unchanged (per-conversation
  profiles retained).

### Migration
No data migration. Existing installs are wiped by `LegacyDataWipe`
once on first launch of this version. See ADR 011 §7.
```

## Migration / Fresh-Start Strategy

**On first launch of the new version**
1. Detect legacy state: pre-refactor keychain entries, pre-refactor XMTP databases, or a version marker
2. If detected: delete all XMTP databases, clear legacy keychain entries, drop and recreate the GRDB database
3. Run silent onboarding (create new identity)
4. Show a brief one-time notice: "Convos has been updated. Your previous conversations are no longer available." (final wording TBD)

**Fresh install**
1. No legacy data present
2. Silent onboarding creates identity
3. User lands on an empty conversation list

## Risks & Open Questions

- **iCloud Keychain data shape constraints**: sync has practical size limits and type restrictions. Our serialized identity (secp256k1 private key + 256-bit db encryption key) is small; expected to fit without issue. Confirmed that app-group keychain items can sync to iCloud under our configuration — no spike needed.
- **Integration-test flakiness (opportunity, not blocker)**: the current Docker-backed integration suite is flaky, largely due to multi-inbox timing races. The Test Agent treats the refactor as an opportunity to de-flake — this is explicitly scoped in C4 and C13. If flake rate does *not* drop measurably after C4, that's a signal we've introduced new timing issues and should pause to investigate before proceeding.
- **XMTP Device Sync edge cases**: enabling device sync silently means a second install discovered via iCloud Keychain on another device can inherit history. Acceptable because we said multi-device is deferred, but behavior should be documented (what happens on iPad + iPhone with the same iCloud account?).
- **Pending invite links in the wild**: invites signed/encoded against the old identity format become unusable. Acceptable within the no-BC stance, but worth a line in release notes.
- **Assistants/agents integration**: confirm assistants still work with single-inbox users (ConvosAgents, ConvosAssistants).
- **Asset renewal (ADR 008)**: verify the single-inbox path for encrypted image renewal.
- **Lock-convo (ADR 006)** and **public preview image toggle (ADR 010)**: verify compatibility; they should be unaffected since they live on group state.
- **Default conversation display (ADR 007)**: should be unaffected.
- **Encrypted images (ADR 009)**: unaffected at the crypto layer; unrelated to identity.
- **NSE decryption after keychain format change**: verify NSE continues to decrypt push-delivered messages after the identity schema changes.
- **ConvosAppData package**: still needed for invite tags in appData and legacy codec support. Slimmer scope but kept.

## Follow-up Plans

- **`docs/plans/invite-system-single-inbox.md`** — full redesign of the invite system for the single-inbox world; must land before invite code changes beyond the shim
- **`docs/plans/integration-test-stabilization-log.md`** — living document maintained by the Test Agent throughout the refactor; captures before/after flake rates per checkpoint and any integration-test fixes applied. Supports the secondary goal of making the integration suite reliable.
- **Multi-device UX** (deferred) — pairing flow, recovery phrase, installation management, device sync user controls
- **Native XMTP profiles** — migrate off our `ProfileUpdate` codec when the protocol ships profile support

## Kickoff Checklist

### Pre-flight

- [ ] `dev` branch up to date locally
- [ ] Docker working: `./dev/up` succeeds, `./dev/down` cleans up
- [ ] `convos-task` in PATH (`which ct`)
- [ ] Full plan read by whoever's orchestrating

### Create the integration branch

```bash
git checkout dev
git pull
git checkout -b single-inbox-refactor
git push -u origin single-inbox-refactor
```

### Wave 1 — spawn core + all 5 validators via Agent Teams

The team is created and managed from the lead session (this conversation). Steps the lead performs:

1. `TeamCreate` — name `single-inbox-refactor`, description matches the work.
2. Populate the shared task list with the 14 checkpoints + ongoing validator tasks (via `TaskCreate` + `TaskUpdate` to set `blockedBy` dependencies).
3. Spawn 6 teammates via the `Agent` tool, passing `team_name="single-inbox-refactor"` and a `name` per teammate. Use the appendix prompt as the spawn prompt for each. Suggested model split: Opus for `core`, Sonnet for the 5 validators.
4. Assign initial tasks via `TaskUpdate` setting `owner`.

### Wave 2 — UI (after C9 completes in the shared task list)

When the C9 task is marked `completed`, spawn the `single-inbox-ui` teammate the same way. Only one Wave 2 teammate — everyone else is already running.

### Closeout

- [ ] `core` reports C1–C10 and C12 merged
- [ ] `ui` reports C11 and C13 implementation pieces merged
- [ ] `qa` reports green; final CXDB report attached to the PR description
- [ ] `tests` reports green 3× clean; final flake-rate table published to the stabilization log
- [ ] `review` reports no blocking findings; all architectural notes resolved or explicitly deferred
- [ ] `security` signs off on C3, C6, C7, C9, C10, C12 with no unresolved blockers
- [ ] `docs` confirms ADR touches all landed; ADR 011 drafted; release notes ready
- [ ] C14 ADR sweep done (ADR 011 canonical, 002/003 Superseded, 004/005 amended)
- [ ] Open PR: `single-inbox-refactor` → `dev`

## Appendix: Initial prompts per teammate

Each prompt is self-contained. Paste it as the first message to the corresponding `ct` session.

**`single-inbox-core`**
> Core implementation teammate for the single-inbox identity refactor. Read `docs/plans/single-inbox-identity-refactor.md` end-to-end before starting. Your scope is checkpoints **C1 → C2 → C3 → C4 → C5 → C6 → C7 → C8 → C9 → C10 → C12**, executed strictly in that order. C11 and C13 implementation bits are owned by the `single-inbox-ui` teammate.
>
> For each checkpoint:
> 1. Read the checkpoint's Code / ADR / QA / Tests lines in the plan.
> 2. Implement the code changes.
> 3. Land the ADR and QA test edits **in the same commit** as the code.
> 4. Run `/lint` and `/test`; fix any issues.
> 5. Merge into `single-inbox-refactor`.
> 6. Wait for the five validators (`qa`, `tests`, `review`, `security`, `docs`) to report green before starting the next checkpoint. Security findings at C3, C6, C7, C9, C10, C12 are blockers.
>
> Before starting C10, collaborate with `single-inbox-docs` to land `docs/plans/invite-system-single-inbox.md` — the shim must align with the full redesign.
>
> Follow CLAUDE.md conventions: Graphite workflow, `/lint`, `/build`, `/test`. Never skip hooks. When a Swift test suite run is required for a checkpoint, run `./dev/up && swift test --package-path ConvosCore && ./dev/down`.

**`single-inbox-ui`**
> UI implementation teammate. Scope: C11 (ViewModel rewiring, Quickname view layer wiring to the new GRDB-backed storage) and the implementation side of C13 (re-enable tests disabled in C2). Do not start until C9 has merged into `single-inbox-refactor`; `gt sync` before starting. Read `docs/plans/single-inbox-identity-refactor.md` end-to-end.
>
> Do **not** edit `SessionManager`, `SessionStateMachine`, `KeychainIdentityStore`, or `MyProfileWriter` — coordinate with `single-inbox-core` via findings if you need changes there. Your work is confined to ViewModels, Views, the Quickname UI storage binding, and re-enabling disabled tests.
>
> Same commit rhythm as core: code + ADR + QA changes in the same commit; `/lint` and `/test` before merging into `single-inbox-refactor`.

**`single-inbox-qa`**
> QA teammate. Read `qa/RULES.md` and `qa/SKILL.md` before starting. Establish a CXDB baseline run against the current tip of `single-inbox-refactor` before any changes land. After each checkpoint merges, re-run the relevant subset of `qa/tests/structured/*.yaml` and log bugs, accessibility gaps, and regressions to CXDB. Each checkpoint's "QA" line in `docs/plans/single-inbox-identity-refactor.md` tells you which test files are expected to change.

**`single-inbox-tests`**
> Test teammate. First task: run `./dev/up && swift test --package-path ConvosCore && ./dev/down` 10× against the current tip of `single-inbox-refactor` and record the baseline flake rate (per-test pass/fail) in `docs/plans/integration-test-stabilization-log.md` (create the file if missing — leave narrative sections blank for `single-inbox-docs` to fill). After each checkpoint merges, re-run and update the log. C4 and C13 are the biggest de-flake opportunities — drive flake rate toward zero. Each checkpoint's "Tests" line in `docs/plans/single-inbox-identity-refactor.md` lists expectations.

**`single-inbox-review`**
> Code review teammate. Review every diff merged into `single-inbox-refactor` as checkpoints land. Use `code-reviewer` for line-level review and `swift-architect` for structural reviews (especially C4, C5, C8). Look for architectural drift from `docs/plans/single-inbox-identity-refactor.md`, anti-patterns, bugs, missing tests, CLAUDE.md/SwiftLint violations, dead code, and gratuitous complexity. Do not push code — file annotated findings back to the implementation teammate via the orchestrator. If you spot plan drift, flag it; `single-inbox-docs` will land the plan edit.

**`single-inbox-security`**
> Security review teammate. Focused on the privacy + crypto boundary of this refactor. Read `docs/plans/single-inbox-identity-refactor.md` end-to-end with special attention to the "Privacy properties we keep/lose" section of Motivation.
>
> Review these checkpoints as they land:
> - **C3** — keychain attributes: verify the access class does not weaken, iCloud sync does not expose material outside expected scope, app-group sharing still grants NSE access and nothing more.
> - **C6** — XMTP device sync: verify identity linkability properties.
> - **C7** — push routing: confirm the backend never receives `inboxId`.
> - **C9** — explode flow: verify no ciphertext leaks, no unintended retention after remove+leave.
> - **C10** — invite shim: flag any sender-privacy regression for the invite follow-up plan.
> - **C12** — App Clip handoff: verify the keychain handoff doesn't expose keys to unauthorized processes.
>
> Do not push code. A security finding on any of those checkpoints is a **blocker** for that checkpoint — escalate to the implementation teammate and the orchestrator.

**`single-inbox-docs`**
> Documentation teammate. Keep `docs/` in sync with code throughout the refactor.
>
> Ongoing responsibilities:
> 1. After each checkpoint merges, verify the ADR touches listed in the plan actually landed. If any were forgotten, open a small doc-only PR to `single-inbox-refactor` with the missing amendments.
> 2. Before C10, draft `docs/plans/invite-system-single-inbox.md` in collaboration with `single-inbox-core`.
> 3. Maintain the narrative in `docs/plans/integration-test-stabilization-log.md` — `single-inbox-tests` provides the raw numbers; you add per-checkpoint commentary and the final summary.
> 4. At C14, draft "ADR 011 – Single-Inbox Identity Model" as the canonical replacement for ADR 002. Mark ADR 002/003 Superseded and confirm 004/005 amendments read cleanly.
> 5. Draft the PR description and release notes at closeout.
> 6. Watch for plan drift: when implementation diverges from `docs/plans/single-inbox-identity-refactor.md`, land a plan edit in a doc-only commit.

## ADR Updates at Merge

- **ADR 002**: status → Superseded; add pointer to this plan
- **ADR 003**: status → Superseded (lifecycle management is removed)
- **ADR 004**: amend "Decision" to reflect the remove-all-then-leave mechanic; preserve the historical context section
- **ADR 005**: amend the "Per-Conversation Profiles" section — the local user's profile is now global; other members' profiles remain per-conversation; remove the Quickname section
