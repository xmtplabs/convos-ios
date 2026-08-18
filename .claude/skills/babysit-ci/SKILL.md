---
name: babysit-ci
description: Babysit a PR's CI to completion - poll the checks, read Macroscope's review findings (which are not status checks and so never show up green/red), triage failures into infra flakes vs real breaks, push fixes, and merge into `dev` once green. Use when the user says "babysit CI", "watch CI", "fix CI and merge", "merge when green", or asks to monitor a PR until it can land.
---

# babysit-ci

Babysit one PR from "checks pending" to "merged into dev". The user has already
said the end state they want, so do not re-ask for permission at each step.
Stop and report only at the explicit stop conditions below.

## Scope guard

- PRs targeting `dev` only. Refuse a PR targeting `main` (a release promotion)
  and hand it back to the user.
- Never push to `dev` directly; every fix goes to the PR branch.
- Never touch version files or `Convos.xcodeproj/project.pbxproj` in a fix
  commit unless the failure is specifically about them.

## 0. Ask the merge intent up front

Before anything else, ask once whether to auto-merge when the PR goes green:
"Auto-merge #<num> into `dev` once green, or babysit and stop when it's ready?"
**The default is NOT to auto-merge.** Only an explicit "yes / auto-merge /
merge when green" enables step 5; anything else means babysit-only. Don't ask
again later.

## 1. Resolve the target PR

Argument may be a PR number or branch name. With no argument, use the current
branch's PR:

```sh
gh pr view [<number-or-branch>] --json number,title,isDraft,baseRefName,headRefName,mergeable,reviewDecision,headRefOid
```

Abort with a clear message if there is no open PR. Note the head SHA: every
check and every Macroscope finding below must be read against the current head,
not a stale run from an earlier push.

## 2. Read Macroscope FIRST, before any polling

Macroscope posts findings as PR review comments, **not** as a CI status check.
They are invisible in `gh pr checks`, so a fully green table says nothing about
them. It also runs early, landing findings a minute or two after the PR opens
while the long checks are still running — which is exactly the window in which
someone merges on a green-looking table.

On PR #1329 it caught three real bugs the green checks did not: a shared-slot
race across concurrent flows, a stale identifier surviving reconciliation, and
state bound to the wrong object on one code path. None of them were style nits.

So read Macroscope **before the first poll**, surface anything real in that same
message, then re-read on every poll and once more before merging (step 4b).

## 3. Poll the checks

```sh
gh pr checks <num>
gh run list --branch <head-branch> --limit 10 --json databaseId,workflowName,status,conclusion,headSha
```

The checks on a typical PR here, with rough durations:

| Check | Typical | Notes |
|---|---|---|
| KeychainIdentityStore Tests (no-op) | ~10s | Path-filtered stub; near-instant. |
| SwiftLint | ~30s | Fastest real signal. |
| Version Alignment | ~1m30s | Marketing/build version consistency. |
| Claude Code Review | ~2m30s | Advisory; not a merge gate. |
| ConvosCore Tests | ~5m | Two jobs: Unit Tests and Integration Tests. |
| Firebase PR Build | ~6m30s | Full archive + ad-hoc distribution. |

Foreground `sleep` is blocked in the harness. Poll with an until-loop inside a
single Bash call (max timeout 600000ms, so ~3 polls per call), then issue
another call:

```sh
for i in $(seq 1 20); do
  sleep 30
  PENDING=$(gh run list --branch <head-branch> --limit 10 --json status \
    --jq '[.[] | select(.status != "completed")] | length')
  [ "$PENDING" = "0" ] && break
done
gh run list --branch <head-branch> --limit 10
```

Between polls, tell the user what changed — which suites finished, which are
still running, any new failure or Macroscope finding. One line per state
change, not raw check tables.

## 4. On failure: triage before touching anything

```sh
gh run view <run-id> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | {name, databaseId}'
gh api repos/xmtplabs/convos-ios/actions/jobs/<job-id>/logs | grep -aE "error:|FAIL|✗|failed" | head -40
```

Classify, then act:

| Failure | First action |
|---|---|
| SwiftLint | `swiftlint lint --strict --quiet Convos/` locally, fix, commit, push. Never `// swiftlint:disable` past it. |
| SwiftFormat drift | `swiftformat .`, commit the result. |
| ConvosCore unit test | Reproduce locally: `./dev/up` then `swift test --package-path ConvosCore`. Most tests need the Docker stack. |
| Integration Tests: `Connection refused 127.0.0.1:5556`, Herald/backend timeouts, Fly deploy errors | Infra, not code. Rerun (see the rerun rule below). |
| `took NNNms to type-check (limit 100ms)` in the archive | Real, and it will not reproduce locally: local builds pass at ~95ms while the CI archive trips at ~107ms. Fix the expression — hoist typed `let`s, split the modifier chain, extract the subview. Never raise the threshold. |
| NotificationService "unable to resolve module dependency" | Configuration mismatch, not a missing file. The Debug configuration breaks module resolution; builds must use `-configuration Dev`. |
| Firebase PR Build signing/provisioning | Usually a secrets or certificate issue on the runner, not this PR. Rerun once, then report. |

### The rerun rule

Always rerun the **whole workflow**, never `--failed`:

```sh
gh run rerun <run-id>          # correct
gh run rerun <run-id> --failed # do not use
```

Integration Tests depends on an ephemeral Fly backend deployed inside its own
job. A partial rerun has skipped that setup and left the job hanging until it
times out. Rerunning the whole workflow is slower but actually completes.

Caps — stop and report rather than looping forever:

- Max **2 reruns** per workflow run.
- Max **2 fix commits** pushed. If CI is still red after that, summarize what
  failed, what was tried, and the candidate causes (proven vs guessed), and
  stop.

Every fix push resets the poll loop: new head SHA, new runs, and Macroscope
re-reviews.

**Verify locally before pushing a fix.** Build and run the suite against the
final code — `swiftlint lint --strict --quiet Convos/`, then
`swift test --package-path ConvosCore` with the Docker stack up. Do not push a
speculative fix and use CI as the test runner; each round trip is 6+ minutes.

Leave the shared Docker stack running when done. Other worktrees and sessions
use the same compose project, and `./dev/down` kills their in-flight tests.

## 4b. Read Macroscope: first, every poll, and last

```sh
# Inline review comments (file/line scoped) — where the real findings land
gh api repos/xmtplabs/convos-ios/pulls/<num>/comments \
  --jq '.[] | select(.user.login | test("macroscope"; "i")) | {path, line, body}'
# Top-level PR comments
gh pr view <num> --json comments \
  --jq '.comments[] | select(.author.login | test("macroscope"; "i")) | {body, createdAt}'
```

Only consider comments against the **current head SHA** — Macroscope re-runs on
each push, so dismiss findings a later fix commit already addressed.

| Finding | Action |
|---|---|
| Real bug or correctness issue in this PR's diff | Fix, commit, push (counts against the 2-fix-commit cap). |
| Style or a suggestion you disagree with | Note it in the wrap-up; don't block the merge. |
| Code this PR didn't touch | Ignore for merge purposes; mention if notable. |

Judge the fix rather than pasting its suggested diff. On #1329 the suggested
one-liner would have overwritten a selection the user made while a fetch was
still in flight; the finding was right and the patch was not.

If real findings are unresolved, do not merge — treat them like a failing
check: fix or report, then re-poll.

## 5. Merge

Mergeable when ALL of these hold on the current head SHA:

- Every required check is green.
- `reviewDecision` is not `CHANGES_REQUESTED`. If an approval is required and
  absent, report "green but waiting on review" and stop — do not bypass.
- No unresolved Macroscope findings you judge to be real.
- Base is `dev`.

Then act on the intent captured at step 0. Auto-merge confirmed up front means
merge without further prompting; otherwise report that it is green and ready
and leave it for the user.

```sh
gh pr merge <num> --squash --delete-branch
```

Squash matches recent `dev` history; honor an explicit different instruction.

## 6. Wrap up

Report the merge commit, total wall time, and any reruns or fix commits that
were needed. If a stacked Graphite branch sits on top of this one, mention
`gt sync` to restack it onto fresh `dev`.
