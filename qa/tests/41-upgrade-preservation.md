# 41 - Upgrade Preservation (dev -> agents-as-contacts branch)

The data-preservation counterpart to test 13. Test 13 verifies the single-inbox
LegacyDataWipe (data is GONE after upgrade); this test verifies the OPPOSITE for the
agents-as-contacts + consent-driven feed-visibility branch: upgrading an existing dev
install to this branch must keep every conversation, message, contact, and block.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Upgrade migrates in place; no full wipe | `LegacyDataWipe.currentGeneration` unchanged ("convos-v2") | `no_wipe_fired` |
| Conversations + messages survive | additive GRDB migrations; in-place `ALTER TABLE DROP COLUMN` | `conversations_preserved` |
| Named human contact stays a pill-less contact | `Contact+BrowseVisibility.isVisibleInContactsList` (human branch) | `human_contact_preserved` |
| Agent contact survives (re-mirrors its pill) | `addContactAgentTemplateFields` (nullable) + `ContactSyncCoordinator` re-mirror | `agent_contact_resyncs` |
| Blocked state survives | `contact.blockedAt` preserved by `replacingProfileFields` | `blocked_state_preserved` |

## The static verdict (why this PR is safe in production)

The investigation that produced this test found the upgrade is **safe on the shipping
(non-DEBUG) build**:

- **No schema-generation bump.** `LegacyDataWipe.swift` is byte-identical on dev and this
  branch and `currentGeneration` is `"convos-v2"` on both. A dev build already stamped
  `convos.schemaGeneration = convos-v2`, so `runIfNeeded` early-returns and the legacy
  wipe never fires. The DB filename (`convos-single-inbox.sqlite`) is unchanged, so the
  same file is migrated in place.
- **Six new migrations, all data-safe.** Five are purely additive (CREATE TABLE / ADD
  COLUMN / CREATE INDEX IF NOT EXISTS). The only destructive one,
  `dropConversationQuarantineFields`, is an in-place native `ALTER TABLE "conversation"
  DROP COLUMN ...` (GRDB 7.5 emits real DROP COLUMN on iOS's modern SQLite) - it is NOT a
  create-new + copy + drop-old table rebuild, so there is no incomplete-copy row-loss
  path. No migration runs DELETE or UPDATE; the only raw SQL is CREATE INDEX.
- **Visibility re-keyed onto an existing column.** Dropping the quarantine columns loses no
  live feed state because feed visibility now derives from the pre-existing
  `conversation.consent` column (commit beb48033), enforced by `ConversationConsentReconciler`
  rather than a read-side quarantine predicate.
- **`contact.blockedAt` is not new** here - it predates this branch on dev; only
  `agentTemplateId` / `agentTemplatePublishedURL` / `agentTemplateEmoji` are new contact
  columns (nullable, no backfill).

## The append-only migration invariant (why this runs on a DEBUG build)

`SharedDatabaseMigrator.createMigrator()` sets `migrator.eraseDatabaseOnSchemaChange = true`
under `#if DEBUG`. GRDB's `hasSchemaChanges` replays a temporary database **up to the
last-applied migration** and erases the real DB if the schemas differ. So a migration
registered **before** dev's last migration (`addAgentBuilderSummaryConnectionsAppliedAt`)
makes the temp-replay schema diverge from a real dev DB -> GRDB wipes it on first launch.

This matters for real users, not just local developers: the `Dev` and `PR Preview` configs
that go to **TestFlight are DEBUG** (only the App Store `Prod`/`Release` config is not). An
earlier revision of this branch registered two new migrations
(`createBuilderBundleHiddenMessage`, `createAgentTemplateContactTable`) mid-list, which
would have wiped every dev/preview tester's local database on update. The fix: all new
migrations are now **appended after dev's last migration**, so the temp-replay equals the
on-disk dev schema, `hasSchemaChanges` returns false, and the upgrade migrates in place on
every configuration - DEBUG Local/Dev/PR included.

Consequence for this test: it runs on the **standard Local (DEBUG) build** and reuses the
local-stack infrastructure (no special non-DEBUG build needed). The `no_wipe_fired` step is
the regression guard for the invariant - if a future change inserts a migration mid-list,
that step fails on the Local build because the DB was erased. Keep new migrations appended
at the bottom of `createMigrator`'s registration list.

## Behavior changes that are NOT data loss (do not assert as preserved)

- **Agent contacts transiently disappear** right after upgrade. `agentTemplateId` is added
  as NULL with no backfill, and `isVisibleInContactsList` hides an agent whose
  `agentTemplateId` is nil. The row + `agentVerification` survive; the contact returns with
  its Agent pill once a profile/membership event re-mirrors the template (open its
  conversation / send a message / let catch-up run). Assert presence AFTER driving the
  re-sync. This is the highest "looks-like-loss" risk and the one finding worth a second
  look from the team (a launch backfill of `agentTemplateId` from the member profile would
  remove the window).
- **Blocking the creator of a conversation now demotes it** (consent reconciler) - a
  conversation visible-despite-blocked-creator on dev becomes hidden after upgrade. Assert
  it is hidden, with the row + messages still reachable via the contact card. Unblock never
  promotes `.denied` back to `.allowed`, so do not assert unblock restores it.
- **Dropped quarantine columns** (`quarantinedAt` / `quarantineReleasedAt`) are intentionally
  gone. Assert the conversation ROW survives, not the quarantine metadata.
- **`StaleStrangerGC`** hard-deletes empty `consent == unknown` conversations whose XMTP
  `createdAt` is older than 7 days, at launch. Seed stranger fixtures with a message or a
  recent timestamp if they must survive - their deletion is by design, not a migration bug.

## Lighter, authoritative guard (recommended)

A UI upgrade test is heavy (two non-DEBUG builds, a worktree, an isolated simulator) and is
gated on build configuration. The cheaper, CI-runnable, deterministic proof is a
**GRDB-level migration unit test** in `ConvosCoreTests` that: builds a DB up to dev's last
migration, seeds representative `conversation` / `contact` / `message` rows (including a
conversation with the quarantine columns populated and a contact with `blockedAt`), runs the
remaining branch migrations with `eraseDatabaseOnSchemaChange = false` (the production path),
and asserts row counts and `blockedAt` survive while the quarantine columns are gone and the
new columns exist. This needs a one-line test seam (make
`SharedDatabaseMigrator.createMigrator()` internal so a `@testable` test can disable the
DEBUG erase and call `migrate(_:upTo:)`). It runs on macOS via `swift test` with no Docker
and no simulator. Strongly preferred as the day-to-day regression guard; this UI test
remains the canonical end-to-end procedure.

## Runbook (isolated simulator, like test 13)

```bash
cd <this convos-ios checkout>
LS="$(git rev-parse --show-toplevel)/dev/local-stack"
make -C "$LS" status                 # backend/herald/worker/minio = 200

SIM=<clone of a base iPhone sim, e.g. convos-<branch>-upgrade>
DEV_WT=/tmp/convos-upgrade-dev
git worktree add "$DEV_WT" dev

# Standard Local build of both sides (migrations are append-only, so DEBUG is fine).
# dev side:
xcodebuild build -project "$DEV_WT/Convos.xcodeproj" -scheme "Convos (Local)" \
  -derivedDataPath "$DEV_WT/.derivedData" -destination "id=$SIM"
# install + launch dev, authorize, populate (see populate_on_dev), terminate.
# branch side (this checkout):
xcodebuild build -project Convos.xcodeproj -scheme "Convos (Local)" \
  -derivedDataPath .derivedData -destination "id=$SIM"
# install OVER the dev app (same bundle id, NO erase), launch, run the assertions.

git worktree remove "$DEV_WT"
```

> The `no_wipe_fired` step confirms the upgrade migrated in place (no LegacyDataWipe, no
> GRDB erase). It passes on this Local build only because the migrations are appended after
> dev's last migration; if it ever fails on Local, a migration was inserted mid-list.

## Status

Authored from a verified static investigation of this branch's migrations, the GRDB
`eraseDatabaseOnSchemaChange` semantics (including that Dev/PR TestFlight builds are DEBUG),
and the consent/agent-contact surface. That investigation found - and this branch now fixes
- a mid-list migration insertion that would have wiped dev/preview TestFlight testers' local
databases on update; the migrations are now appended after dev's last migration so the
upgrade migrates in place on every configuration. The migration path is otherwise data-safe
(no generation bump; additive migrations + one in-place column drop; no DELETE/UPDATE). Not
yet run end-to-end (two Local builds + an isolated simulator, like test 13); the recommended
lighter automated guard is the GRDB-level unit test described above.
