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
| F1: Compile regression in asset recovery path | blocker | API/enum drift caused compile failure | done | `swift test --package-path ConvosCore --filter AssetRenewalURLCollectorTests` fails in `ExpiredAssetRecoveryHandler` + `SessionManager`; `rg` confirms stale enum destructuring call sites | confirmed |
| F2: Batch renewal marks failed keys as renewed | high | non-`not_found` failures still get timestamps | not started |  |  |
| F3: `avatarLastRenewed` lost during conversation sync | high | member profile rows are recreated without preserving timestamp | not started |  |  |
| F4: Startup path cannot auto re-upload expired assets | medium | startup recovery handler lacks cache/writers | not started |  |  |
| F5: Test coverage gaps around recovery/integration | medium | missing tests fail to protect core recovery behavior | not started |  |  |

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
  - Compile is currently blocked by concrete API/enum mismatch errors in both recovery and re-upload call paths.
  - `rg` confirms stale enum destructuring patterns in:
    - `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
    - `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`

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

### Evidence to record
- Failing test (current behavior)
- Expected vs actual key-level outcome table

### Verdict template
- Confirmed? ☐ yes ☐ no ☐ partial
- Why:

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

### Evidence to record
- Before/after DB values for `avatarLastRenewed`
- Exact writer path where reset occurs

### Verdict template
- Confirmed? ☐ yes ☐ no ☐ partial
- Why:

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
| Startup task |  |  |  | clear URL fallback |
| Manual force reupload |  |  |  | cache re-upload possible |

### Evidence to record
- Source references (file+line)
- Behavior outcome for each path

### Verdict template
- Confirmed? ☐ yes ☐ no ☐ partial
- Why:

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
| Compile drift on enum/image cache API |  |  |
| Per-key renewal success accounting |  |  |
| Profile timestamp preservation |  |  |
| Expired asset recovery paths |  |  |
| Startup integration behavior |  |  |

### Verdict template
- Confirmed gaps? ☐ yes ☐ no ☐ partial
- Why:

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
