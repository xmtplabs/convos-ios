---
name: feature-worklog
description: Persistent memory system for multi-milestone features. Survives context windows, enables parallel subagent coordination. Trigger with "create worklog", "start feature worklog", or when feature requires 3+ milestones.
---

# Feature Worklog Skill

Use this skill when implementing features that:
- Require **3+ milestones** to complete
- May span **multiple context windows** (long sessions)
- Need **parallel subagent coordination**
- Have **complex dependencies** between milestones

## Quick Start

1. Create `WORKLOG.md` in project root
2. Copy template from `references/template.md`
3. Fill in feature name, milestones, dependencies
4. Update as you complete work (immediately, not in batches)
5. Archive when feature ships

## When to Use

| Condition | Use Worklog? |
|-----------|--------------|
| 1-2 simple tasks | No |
| 3+ milestones | **Yes** |
| May run out of context | **Yes** |
| Spawning parallel subagents | **Yes** |
| Complex dependencies | **Yes** |
| Single afternoon task | No |

## Start Gate

**WORKLOG.md must be created BEFORE any implementation edits, tests, or refactors.**

Allowed before WORKLOG.md: read-only discovery, setup commands
Blocked before WORKLOG.md: source modifications, test changes, implementation

## Core Principles

### 1. Update Immediately

Update the worklog **as tasks complete**, not at the end of sessions. This ensures memory survives context exhaustion.

### 2. Track Test Counts

Every milestone should record the total test count. This catches regressions and provides progress visibility.

### 3. Coverage Checkpoints

Run coverage after each milestone, not just at the end. Prevents end-of-feature scrambles.

### 4. Mark Deferrals Explicitly

Use `- DEFERRED (reason)` to prevent scope creep and avoid re-discussing settled decisions.

### 5. Log Reviews

The Reviews Log provides audit trail and traceability for QA.

### 6. Context Pressure Awareness

Estimate token requirements before planning parallel work. When context limits make parallel execution impractical, use serial execution with handoffs.

### 7. Include Archive Name in Header

Include the final archived filename in the worklog header. This enables code to cite the permanent location from the start.

```markdown
**Started:** 2026-02-28
**Archive Name:** `docs/worklogs/2026-02-28_feature-name.md`
**Branch:** `feature/feature-name`
```

### 8. Archive as Explicit Milestone

Always include archive as an explicit item in the final milestone:

```markdown
**MN - PR & Archive:**
- [ ] **ASK USER:** "Ready to archive?"
- [ ] **WAIT for explicit user approval**
- [ ] Archive WORKLOG.md: `mv WORKLOG.md docs/worklogs/YYYY-MM-DD_feature-slug.md`
- [ ] Create PR with summary
```

### 9. Worklog First After Compaction

After context compaction, the FIRST action must be to read WORKLOG.md. Do not write code until you have restored context from the worklog.

## Required Worklog Sections

| Section | Required | Purpose |
|---------|----------|---------|
| **Archive Name** | YES | Enables code citations to use permanent path |
| **Constitutional Invariants** | YES | Define what must be true |
| **Security Review** | YES | Adversarial analysis |
| **QA Test Plan** | YES for testable work | Expected/Actual/Status columns |
| **Milestones** | YES | Track completed and pending work |
| **Archive Milestone** | YES | Explicit archive step |

## Constitutional Invariants (required)

Every feature worklog must define constitutional invariants - rules that must be true.

### Invariant Template

```markdown
## Constitutional Invariants

### INV-1: [Short Name]
**Invariant:** [What must be true]
**Rationale:** [Why - reference to spec if applicable]
**Test Strategy:**
- [How to verify in tests]
- [Edge cases to cover]
```

## Security Review - Adversarial Analysis (required)

Every worklog must include adversarial analysis. Ask: "How could a malicious actor abuse this?"

### Template

```markdown
## Security Review - Adversarial Analysis

### Threat 1: [Abuse Scenario]
**Attack:** [Description]
**Impact:** [What damage could occur]
**Mitigation:** [How we prevent/limit it]
**Status:** MITIGATED / ACCEPTED RISK / DEFERRED
```

## iOS-Specific Patterns

### Build Verification

After each milestone, verify:
```markdown
- [ ] Build succeeds: `/build`
- [ ] Lint passes: `/lint`
- [ ] Tests pass: `/test` or `swift test --package-path ConvosCore`
```

### Simulator QA

For UI milestones, include simulator verification:
```markdown
### Simulator QA
- [ ] Build and run: `/build --run`
- [ ] Navigate to [screen]
- [ ] Verify [expected behavior]
- [ ] Screenshot captured (local only, do not commit)
```

### ConvosCore Platform Independence

When modifying ConvosCore, verify macOS compilation:
- No UIKit imports
- Use `ImageType` instead of `UIImage`
- Protocol bridge via ConvosCoreiOS for iOS-specific needs

## Smart Deferral Pattern

### Deferral Criteria Checklist

| Question | If Yes | If No |
|----------|--------|-------|
| Is the bug in code I'm modifying? | Fix it | May defer |
| Does it block the feature? | Fix it | May defer |
| Is the fix safe without the feature? | May couple | Defer |
| Would fixing expand scope significantly? | Defer | May fix |

## Workflow

```text
1. CREATE WORKLOG
   - Copy template to WORKLOG.md
   - Fill in feature name, milestones, invariants
   - Get user approval before starting implementation

2. IMPLEMENT MILESTONES
   - Work through milestones in dependency order
   - Update worklog immediately after each task
   - Record test counts after each milestone
   - Verify builds after each milestone

3. PARALLEL SUBAGENTS (when applicable)
   - Launch independent tasks in parallel
   - Record subagent reports when they complete
   - Aggregate results into worklog

4. CONTEXT CONTINUATION (if needed)
   - On compaction, worklog survives in WORKLOG.md
   - First action: re-read worklog to restore context
   - Continue from last unchecked milestone item

5. ARCHIVE WHEN DONE
   - ASK USER for approval
   - WAIT for explicit approval
   - Move WORKLOG.md to docs/worklogs/YYYY-MM-DD_slug.md
   - Stage archived file, not root WORKLOG.md
```

## Anti-Patterns

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| Batching updates | Context lost if session ends | Update immediately |
| No test counts | Can't detect regressions | Record after each milestone |
| Implicit deferrals | Scope creep, re-discussion | Explicitly mark DEFERRED |
| No dependencies | Wrong execution order | Document dependency graph |
| End-of-feature coverage | Scramble to meet threshold | Check coverage per milestone |
| Committing without archiving | WORKLOG.md clutters repo root | Archive before commit |
| Auto-archiving | User didn't approve | Always ask user first |
| Marking ASK USER checkboxes | Skips required approval | Always wait for user response |
| Forgetting worklog after compaction | Lost context | Read WORKLOG.md first |

## Veto Criteria

- VETO if feature requires 3+ milestones and `WORKLOG.md` is missing
- VETO if milestones or dependencies are not defined
- VETO if completed milestones lack test counts (for testable work)
- VETO if committing/PR with `WORKLOG.md` at repo root (must archive first)
- VETO if archiving without user approval

## References

- Template: `.claude/skills/feature-worklog/references/template.md`
- Worklogs archive: `docs/worklogs/`
