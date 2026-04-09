# Backup & Restore Follow-ups

Deferred work items surfaced during PR #603 (vault-backup-bundle) Macroscope review and Jarod's Loom feedback. Items here are **not** blocking #603 merge — they either belong upstack on #618 (vault-restore-flow) or are enhancements for a later PR.

## Status legend
- **Upstack (#618)**: fix lives on `vault-restore-flow`, not `vault-backup-bundle`
- **Backlog**: enhancement, no PR assigned yet

---

## 1. `ConversationsViewModel.leave()` fights `recomputeVisibleConversations()` — Upstack (#618)

**Source:** Macroscope 🟠 High, `Convos/Conversations List/ConversationsViewModel.swift:413`

`leave(conversation:)` mutates `conversations` directly. The `recomputeVisibleConversations()` flow (added in #618 for stale-inbox recovery) rebuilds `conversations` from `unfilteredConversations` on the next tick, so the leave is visually undone until the DB delete propagates.

**Fix:** adopt the same `hiddenConversationIds` pattern `explodeConversation()` uses. Add the id to `hiddenConversationIds`, call `recomputeVisibleConversations()`, then clear the hidden id once the DB delete observation lands.

**Why deferred:** `recomputeVisibleConversations` and `hiddenConversationIds` were introduced on #618. Fix belongs on that branch.

---

## 2. `staleInboxIdsPublisher()` missing vault filter — Upstack (#618)

**Source:** Macroscope 🟠 High, `ConvosCore/Sources/ConvosCore/Storage/Repositories/InboxesRepository.swift:96`

Sibling publishers (`staleDeviceStatePublisher`, `anyInboxStalePublisher`) filter `isVault == false`. `staleInboxIdsPublisher` does not. A stale vault inbox would have its `inboxId` added to the hidden set and hide its conversations in the list, contradicting the rest of the stale-device logic which intentionally excludes vault inboxes.

**Fix:** add `.filter(DBInbox.Columns.isVault == false)` to the query, matching the other two publishers.

**Why deferred:** publisher and its call site were added on #618.

---

## 3. Disk-space preflight for backup + UI surfacing — Backlog

**Source:** Jarod Q2.

Backup creates a staging directory with a full GRDB copy + per-inbox XMTP archives + the encrypted bundle. Peak usage is ~2–3x final bundle size. Today backups are tiny (~381KB for 7 convos, no images), so this is not urgent — but a user with a much larger DB on a near-full device could hit a mid-backup failure with no warning.

**Proposed work:**
- Add a preflight check in `BackupManager.createBackup()` that reads free space on the staging volume and bails with a dedicated `BackupError.insufficientDiskSpace(required:available:)` before any work begins.
- Pick a conservative multiplier (e.g., estimate `3 * dbFileSize + fixedOverhead`).
- Surface available storage in `BackupDebugView` status rows (next to "Last backup").
- Later: user-facing error copy when surfacing backups in settings.

**Why deferred:** enhancement, current backup sizes make it a non-issue. Not a correctness bug.

---

## 4. Backup size / compression evaluation — Backlog

**Source:** Jarod Q4.

Current observations:
- ~381KB for 7 conversations, text-only.
- Bundle is raw AES-GCM ciphertext, no compression.
- Media is **not** included — encrypted image refs point to external URLs with a 30-day validity.

**Proposed work:**
- Add instrumentation (QA event or debug log) recording bundle size, DB size, and archive count per backup run.
- Collect data from dogfooding across a range of account sizes.
- Revisit compression (`Compression` framework, zlib on the tar stream before AES) if bundles exceed ~5–10MB regularly. Compression before encryption is safe here because bundles are not transmitted over an attacker-observable channel where length-based side channels matter.
- Decide whether media inclusion is in scope for a future backup version.

**Why deferred:** current sizes don't justify the complexity. Need data first.

---

## Out of scope / already handled

- **Vault re-creation on restore** — handled on #618 via `VaultManager.reCreate` + `RestoreManager.reCreateVault`. The single-device "vault is inactive after restore" problem Louis raised is already addressed there.
- **Missing vault archive = silent data loss** — handled on #618 (`RestoreManager` throws `missingVaultArchive`).

## Being fixed on #603 (not deferred)

Listed here for cross-reference; these land on `vault-backup-bundle` itself:

1. `RestoreManager` destructive-ops ordering — stage XMTP files + keychain aside, replace DB, import archives, only then delete the staged state. Covers Macroscope 🟡 `RestoreManager.swift:92` and Jarod Q1.
2. `ConvosVaultArchiveImporter.swift:47` — add `defer` cleanup on the import path.
3. `BackupManager` — fail the backup if `broadcastKeysToVault` fails (Jarod Q3, fail-loud).
4. `BackupDebugView.swift:107` — align `runAction` title with button label so the spinner renders.
