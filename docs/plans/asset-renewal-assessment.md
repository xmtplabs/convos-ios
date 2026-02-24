# Asset Renewal Assessment Plan (Deep Findings)

> Status: in progress
> Branch: `asset-reupload`
> Owner: TBD
> Last updated: 2026-02-24

## Purpose

Validate (with reproducible evidence) the deep findings from review before implementing fixes.

---

## Tracking

| Finding | Severity | Hypothesis | Status | Evidence | Verdict |
|---|---|---|---|---|---|
| F1: Compile regression in asset recovery path | blocker | API/enum drift caused compile failure | done | fixed by updating enum destructuring + cache identifier lookups; `swift test --package-path ConvosCore --filter AssetRenewalURLCollectorTests` now builds/runs | confirmed + fixed |
| F2: Batch renewal marks failed keys as renewed | high | non-`not_found` failures still get timestamps | done | added/updated test `testBatchRenewalRecordsOnlyExplicitlyRenewedKeys`; introduced `renewedKeys` in `AssetRenewalResult` and use it in manager | confirmed + fixed |
| F3: `avatarLastRenewed` lost during conversation sync | high | member profile rows are recreated without preserving timestamp | done | fixed in `ConversationWriter` via preservation helper; added `AvatarRenewalPreservationTests` | confirmed + fixed |
| F4: Startup path cannot auto re-upload expired assets | medium | startup recovery handler lacks cache/writers | done | `SessionManager` startup injects only `databaseWriter`; manual path injects cache + profile/group writers | confirmed |
| F5: Test coverage gaps around recovery/integration | medium | missing tests fail to protect core recovery behavior | done | added manager/accounting tests + avatar renewal preservation tests; recovery/startup integration tests still missing | confirmed (partially addressed) |


---

## Phase 0 — Baseline snapshot

### Objective
Capture current branch/build state and establish a reproducible baseline.

### Commands

```bash
git rev-parse --short HEAD
git status --short
swift test --package-path ConvosCore --filter AssetRenewalURLCollectorTests
```

### Evidence to record
- Commit SHA
- Dirty files
- Build/test output summary (errors and key lines)

### Result
- Status: ☑ done
- Notes:
  - Commit SHA: `fbbbc703`
  - Dirty files at snapshot:
    - `.claude/settings.local.json`
    - `docs/plans/asset-renewal-assessment.md`
  - Baseline command `swift test --package-path ConvosCore --filter AssetRenewalURLCollectorTests` fails with compile errors in:
    - `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
    - `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`

---

## Phase 1 — F1 Compile regression assessment

### Hypothesis
`ExpiredAssetRecoveryHandler` and call sites are out of sync with current `RenewableAsset` shape and `ImageCacheProtocol` API.

### Steps
1. Compile ConvosCore and collect all errors touching:
   - `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
   - `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`
2. Group each error into root cause bucket:
   - enum tuple arity mismatch
   - image cache API mismatch
   - stale call-site destructuring
3. Confirm impacted files via search:

```bash
rg -n "\\.profileAvatar\\(|\\.groupImage\\(" ConvosCore/Sources/ConvosCore
```

### Evidence to record
- Error list by bucket
- File+line list of required updates

### Initial evidence (captured)
- `SessionManager.swift`
  - ambiguous expression in `forceReuploadAssetFromCache` tuple initialization
  - `ImageCacheContainer.shared.image(for: url)` uses unsupported URL overload
- `ExpiredAssetRecoveryHandler.swift`
  - `imageCache.image(for: url)` uses unsupported URL overload
  - enum tuple pattern arity mismatch for `.profileAvatar` and `.groupImage`

### Verdict
- Confirmed? ☑ yes
- Why:
  - Compile was blocked by concrete API/enum mismatch errors in both recovery and re-upload call paths.
  - `rg` confirmed stale enum destructuring patterns in:
    - `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
    - `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`
  - Applied fix:
    - switched cache lookup to identifier-based `image(for: asset.url)`
    - updated enum case destructuring to include `lastRenewed`
    - simplified ambiguous async tuple construction in `SessionManager.forceReuploadAssetFromCache`
  - Re-check: `swift test --package-path ConvosCore --filter AssetRenewalURLCollectorTests` passes.

---

## Phase 2 — F2 Renewal timestamp correctness assessment

### Hypothesis
Batch logic records timestamps for keys that failed renewal with errors other than `not_found`.

### Steps
1. Add/adjust test in `ConvosCore/Tests/ConvosCoreTests/Assets/AssetRenewalManagerTests.swift`:
   - mixed results per key: success + `not_found` + `internal_error`
2. Assert timestamp updates only for true successes.
3. Run targeted test.

### Suggested test scenario matrix

| Key | API outcome | Expected timestamp update |
|---|---|---|
| k1 | success | yes |
| k2 | not_found | no |
| k3 | internal_error | no |

### Evidence recorded
- Initial repro test showed over-record risk when renewal success was inferred by `batch - expiredKeys`.
- Fix implemented:
  - `AssetRenewalResult` now carries `renewedKeys` (derived from backend `results.success`).
  - `AssetRenewalManager` records timestamps using `renewedKeys` only.
- Verification test:
  - `testBatchRenewalRecordsOnlyExplicitlyRenewedKeys`
  - Scenario: one explicit renewed key, one expired key, one unknown failure key.
  - Observed: only explicit renewed key gets timestamp.

### Verdict
- Confirmed? ☑ yes
- Why:
  - The bug existed under inferred-success logic and is now corrected with key-level success accounting.

---

## Phase 3 — F3 Profile timestamp preservation assessment

### Hypothesis
Conversation sync/store path drops `avatarLastRenewed` due to profile delete/reinsert flow.

### Steps
1. Add regression test (ConversationWriter path):
   - seed `DBMemberProfile.avatarLastRenewed` with non-nil
   - run store/sync flow for same conversation/profile/avatar
   - verify `avatarLastRenewed` remains unchanged
2. Trace where loss happens if test fails.

### Evidence recorded
- Initial issue:
  - `ConversationWriter` deleted and recreated `DBMemberProfile` rows per conversation.
  - Incoming profiles from XMTP mapping had `avatarLastRenewed` defaulting to nil.
- Fix implemented:
  - Added `ConversationWriter.preservingAvatarLastRenewed(incomingProfile:existingProfile:)`.
  - During save, existing profile rows are fetched first and `avatarLastRenewed` is preserved only when avatar URL is unchanged.
- Tests added:
  - `AvatarRenewalPreservationTests`
    - preserves when URL unchanged
    - clears when URL changes
    - clears when incoming avatar is nil

### Verdict
- Confirmed? ☑ yes
- Why:
  - Issue reproduced by code path analysis and fixed with explicit preservation logic plus focused tests.

---

## Phase 4 — F4 Auto re-upload startup path assessment

### Hypothesis
Startup renewal cannot auto-reupload because recovery handler is instantiated without image cache and metadata writers.

### Steps
1. Document current dependency wiring:
   - startup path (`SessionManager` initialization task)
   - debug/manual path (`forceReuploadAssetFromCache`)
2. Validate behavior with expired key simulation:
   - when startup handler lacks cache/writers
   - when manual path injects full dependencies

### Dependency matrix

| Path | imageCache | myProfileWriter | conversationMetadataWriter | Expected behavior |
|---|---|---|---|---|
| Startup task | no | no | no | clear URL fallback |
| Manual force reupload | yes | yes | yes | cache re-upload possible |

### Evidence recorded
- Startup path wiring (`SessionManager` init task):
  - `let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: self.databaseWriter)`
- Manual path wiring (`forceReuploadAssetFromCache`):
  - injects `ImageCacheContainer.shared`, `MyProfileWriter`, and `ConversationMetadataWriter`.

### Verdict
- Confirmed? ☑ yes
- Why:
  - Expired assets in startup renewal path cannot be re-uploaded from cache because required dependencies are not injected.

---

## Phase 5 — F5 Coverage gap assessment

### Hypothesis
Current tests do not cover recovery handler behavior and startup integration enough to prevent regressions.

### Steps
1. Inventory current tests in:
   - `AssetRenewalManagerTests.swift`
   - `AssetRenewalURLCollectorTests.swift`
2. Map each finding to existing coverage and missing tests.
3. Propose a minimum guardrail suite.

### Coverage matrix template

| Risk | Existing tests | Missing tests |
|---|---|---|
| Compile drift on enum/image cache API | `AssetRenewalManagerTests`, `AssetRenewalURLCollectorTests` compile indirectly | Direct tests for `ExpiredAssetRecoveryHandler` pattern matching/cache lookup API usage |
| Per-key renewal success accounting | `AssetRenewalManagerTests` now includes explicit renewed-key accounting test | Additional integration coverage across API client parsing + manager path |
| Profile timestamp preservation | `AvatarRenewalPreservationTests` | Full integration test through `ConversationWriter.store` + DB migration state |
| Expired asset recovery paths | none | Unit tests for recovery success/fallback clear-url logic |
| Startup integration behavior | none | Integration test validating startup renewal dependency injection behavior |

### Verdict
- Confirmed gaps? ☑ yes
- Why:
  - Current coverage is strong for collector and manager basics, but weak around recovery handler and end-to-end startup recovery behavior.

---

## Final output expected from assessment

1. For each finding (F1-F5):
   - reproducible steps
   - evidence
   - confirmed verdict
2. Ranked remediation order with dependencies.
3. Test plan for preventing recurrence.

---

## Recommended remediation order (after assessment)

1. Fix F1 compile breakages.
2. Fix F2 per-key renewal accounting.
3. Fix F3 timestamp preservation for member profiles.
4. Address F4 startup recovery wiring policy.
5. Implement F5 regression tests.
