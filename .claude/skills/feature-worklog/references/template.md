# Feature Worklog Template

Copy this template to `WORKLOG.md` when starting a new multi-milestone feature.

---

````markdown
# [Feature Name] Implementation

**Started:** YYYY-MM-DD
**Archive Name:** `docs/worklogs/YYYY-MM-DD_feature-name.md`
**Branch:** `feature/feature-name`

---

## Constitutional Invariants

**These constraints must hold true throughout implementation. Violation is a blocker.**

### INV-1: [Invariant Name]

**Invariant:** [Precise statement of what must be true]
**Rationale:** [Why this matters]
**Test Strategy:**
- [How to verify before implementation]
- [How to verify after implementation]
- [Specific assertion or test case]

### INV-2: [Invariant Name]

**Invariant:** [Statement]
**Rationale:** [Why]
**Test Strategy:**
- [Verification approach]

---

## Current Milestone: [Name]

### Completed Milestones

**M1 - [Milestone Name] (done YYYY-MM-DD):**

- [x] [Task description]
- [x] Build succeeds
- [x] Tests pass (N total)
- [x] COMMIT: `feat([scope]): [description]` (abc1234)

### Remaining Milestones

**M2 - [Milestone Name]:**

- [ ] [Task description]
- [ ] Build succeeds
- [ ] Tests pass
- [ ] COMMIT: `feat([scope]): [description]`

**MN - Archive:**

- [ ] **ASK USER:** "Ready to archive?"
- [ ] **WAIT for explicit user approval**
- [ ] Archive WORKLOG.md: `mv WORKLOG.md docs/worklogs/YYYY-MM-DD_feature-name.md`
- [ ] Create PR with summary

---

## Commit Checkpoint Summary

| Order | Commit Message | Type | SHA |
|-------|----------------|------|-----|
| 1 | `feat([scope]): [description]` | impl | - |

---

## QA Test Plan

### Prerequisites

- [ ] App builds and runs on simulator
- [ ] Test environment configured

### Test Scenarios

| Scenario | Steps | Expected | Actual | Status |
|----------|-------|----------|--------|--------|
| [Happy path] | [Steps to reproduce] | [Expected result] | | TODO |
| [Edge case] | [Steps to reproduce] | [Expected result] | | TODO |
| [Error case] | [Steps to reproduce] | [Expected result] | | TODO |

### Simulator QA

- [ ] Build and run on simulator
- [ ] Navigate to [screen]
- [ ] Verify [expected behavior]
- [ ] Dark mode verified
- [ ] Dynamic type verified
- [ ] VoiceOver verified

---

## Dependencies

```text
M1 ([description])
    ├── M2 ([description]) - depends on M1
    └── M3 ([description]) - depends on M1
```

---

## Deferred (V2+)

Items explicitly out of scope for this feature:
- [ ] [Deferred item] - [reason]

---

## Security Review - Adversarial Analysis

### Threat 1: [Abuse Scenario]

**Attack:** [Description]
**Impact:** [What damage could occur]
**Mitigation:** [How we prevent/limit it]
**Status:** MITIGATED / ACCEPTED RISK / DEFERRED

---

## Key Design Decisions

1. **[Decision]:** [Rationale]
2. **[Decision]:** [Rationale]

---

## Reviews Log

| Milestone | Date | Reviewer | Result | Notes |
|-----------|------|----------|--------|-------|
| M1 | YYYY-MM-DD | [agent/person] | PASS/FAIL | [notes] |

---

## Test Coverage Tracking

| Module | Before | After | Notes |
|--------|--------|-------|-------|
| ConvosCore | N tests | N tests | [what was added] |

---

## Rollback Plan

If feature needs to be reverted:
1. `git revert <commit-sha>` - [describe impact]
2. [Any database migration rollback or "no rollback needed"]

---

## Archive Checklist

- [ ] All tests passing
- [ ] Lint passes: `/lint`
- [ ] Build succeeds: `/build`
- [ ] WORKLOG.md moved to `docs/worklogs/YYYY-MM-DD_feature-name.md`
- [ ] PR created

---

## Notes

Any additional context, gotchas, or learnings during implementation.

````
