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

## Why this MUST be built non-DEBUG (the one real trap)

`SharedDatabaseMigrator.createMigrator()` sets `migrator.eraseDatabaseOnSchemaChange = true`
under `#if DEBUG`. GRDB's `hasSchemaChanges` replays a temporary database **up to the
last-applied migration** and compares it to the real DB. This branch registers two new
migrations - `createBuilderBundleHiddenMessage` and `createAgentTemplateContactTable` -
**before** dev's last migration (`addAgentBuilderSummaryConnectionsAppliedAt`) in the
registration list. So the temp-replay-to-last-applied schema contains two tables a real
dev DB does not yet have, the schemas differ, and **in DEBUG GRDB erases the whole
database** on first launch of the branch build.

Consequences:

- `Dev`, `Local`, and `PR` configs all define DEBUG. A stock Local/Dev upgrade build will
  **wipe the DB** and this test would report total data loss that does NOT happen in
  production. `Prod` defines no DEBUG, so the shipping App Store / TestFlight upgrade keeps
  `eraseDatabaseOnSchemaChange = false` and migrates in place.
- Run this UI test with the **Prod scheme**, or build the Local/Dev scheme with
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` overridden to drop `DEBUG`. The `no_wipe_fired` step
  is the gate that you are in a valid configuration.
- This is also a **developer-experience note**: any engineer who builds this branch over an
  existing dev DEBUG install loses their local DB on next launch. It self-heals (fresh DB)
  and is not a production bug, but appending the two new migrations to the END of the
  registration list (after `addAgentBuilderSummaryConnectionsAppliedAt`) instead of mid-list
  would avoid the DEBUG erase entirely.

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

# Build BOTH sides non-DEBUG (Prod scheme shown; or override DEBUG out of Local/Dev).
# dev side:
xcodebuild build -project "$DEV_WT/Convos.xcodeproj" -scheme "Convos (Prod)" \
  -derivedDataPath "$DEV_WT/.derivedData" -destination "id=$SIM"
# install + launch dev, authorize, populate (see populate_on_dev), terminate.
# branch side (this checkout):
xcodebuild build -project Convos.xcodeproj -scheme "Convos (Prod)" \
  -derivedDataPath .derivedData -destination "id=$SIM"
# install OVER the dev app (same bundle id, NO erase), launch, run the assertions.

git worktree remove "$DEV_WT"
```

> If you build the Local/Dev scheme instead of Prod, strip DEBUG for the build, e.g.
> `xcodebuild ... SWIFT_ACTIVE_COMPILATION_CONDITIONS=""` - otherwise GRDB erases the DB and
> the test is invalid. Confirm via `no_wipe_fired`.

## Status

Authored from a verified static investigation of this branch's migrations, the GRDB
`eraseDatabaseOnSchemaChange` semantics, and the consent/agent-contact surface. Not yet run
end-to-end (it requires two non-DEBUG builds + an isolated simulator, like test 13). The
production migration path is statically safe (no generation bump; additive migrations + one
in-place column drop; no DELETE/UPDATE); the recommended automated guard is the GRDB-level
unit test described above.
