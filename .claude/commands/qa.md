---
description: Run the Convos iOS QA suite (structured tests in qa/tests/structured/*.yaml). Results are persisted to CXDB so runs resume across context resets.
---

# /qa

Orchestrate a QA run. This command is the **Claude Code** entry point to the QA corpus defined in `qa/` — the same corpus pi uses via `.pi/skills/qa`. The heavy lifting of each individual test happens in the `qa-runner` subagent; this command plans the run and aggregates results.

## Arguments

| Usage | Meaning |
|-------|---------|
| `/qa` | Run the full suite in the recommended order. Resumes the active run if one exists in CXDB. |
| `/qa <id>` | Run a single test, e.g. `/qa 05`, `/qa 23b`. |
| `/qa <id> <id> ...` | Run just these tests, in the given order. |
| `/qa resume` | Explicitly resume the active run. |
| `/qa new` | Start a new run even if an active one exists. |
| `/qa report` | Render the latest run to `qa/reports/run-<id>.md` and print the summary. |
| `/qa list` | List available tests with their current status in the active run. |
| `/qa --sequential` | Disable parallel fanout (run everything on the primary simulator). Default is to fan out migration onto its own simulator in parallel with the main sequence. |
| `/qa --dry-run` | Verify preconditions (simulator, idb, convos CLI, cxdb.sh, built app, available YAMLs) and print what the run would do. No dispatches, no CXDB writes. |

## Before dispatching

1. **Read the playbook** if this is the first `/qa` call in the session:
   - `qa/RULES.md` — the contract (Read-Only Policy, log monitoring, ephemeral UI, multi-simulator, pasteboard safety, no-sleep, etc.).
   - `qa/TOOLS-CLAUDE.md` — pi `sim_*` vocabulary → Claude MCP / Bash mapping. **Always use this when translating YAML actions.**
   - `qa/tests/structured/README.md` — action/verify/criteria semantics.
2. **Resolve the primary simulator UDID.** Read `.claude/.simulator_id`. If missing, fall back to `.convos-task` `SIMULATOR_NAME` or derive from `git branch --show-current` per `qa/RULES.md` "Simulator Selection", then resolve via `xcrun simctl list devices -j`. If the simulator doesn't exist, run `/setup` first and abort.
2a. **Verify prerequisites.** The runner needs all of these — abort with clear install instructions if any are missing:
   ```bash
   # idb — the primary UI-automation tool. Check common install locations.
   IDB=""
   for p in "$IDB_OVERRIDE" "/Users/$(whoami)/Library/Python/3.9/bin/idb" "$HOME/Library/Python/3.9/bin/idb" "/opt/homebrew/bin/idb" "/usr/local/bin/idb" "$(command -v idb 2>/dev/null)"; do
     [ -n "$p" ] && [ -x "$p" ] && IDB="$p" && break
   done
   [ -z "$IDB" ] && { echo "❌ idb not found. Install: python3 -m pip install --user fb-idb. Or set IDB_OVERRIDE to the binary path."; exit 1; }

   # convos CLI
   command -v convos >/dev/null || { echo "❌ convos CLI not on PATH. Install per ~/.convos setup docs."; exit 1; }
   convos identity list >/dev/null 2>&1 || convos init --env dev --force

   # cxdb.sh — exec bit can be dropped by git on some checkouts
   [ -x qa/cxdb/cxdb.sh ] || chmod +x qa/cxdb/cxdb.sh
   ```
3. **Verify the app is running.** Take a quick screenshot. If it isn't, run `/run` to build + install + launch. This may take a few minutes; report progress.
4. **Prepare the simulator once** per session (idempotent — safe to re-run):
   ```bash
   xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
   xcrun simctl spawn "$UDID" defaults write -g UIAnimationDragCoefficient -int 0
   ```
   Then relaunch the app so it picks up Reduce Motion.
5. **Initialize CXDB.**
   ```bash
   CXDB=qa/cxdb/cxdb.sh
   ACTIVE=$($CXDB active-run)
   ```
   - With no args or `resume`: if `$ACTIVE` is non-empty, reuse it. Otherwise start a new one.
   - With `new`: start a new run regardless.
   - Starting fresh:
     ```bash
     RUN=$($CXDB new-run "$UDID" "$(git rev-parse --short HEAD)" "iPhone")
     ```
6. **Verify `convos` CLI.** `convos identity list`. If it errors, `convos init --env dev --force`.

## `/qa --dry-run`

Do every step in "Before dispatching" 1-4 and 2a (simulator resolve, prerequisite check, sim prep) but **skip 5, 6, and the actual dispatch**. Instead, print a readiness report and exit.

```bash
# Readiness report
echo "=== /qa --dry-run ==="
echo "Simulator:     <SIMULATOR_NAME> ($UDID)"
echo "idb:           $IDB"
echo "convos CLI:    $(command -v convos) ($(convos --version 2>/dev/null | head -1))"
echo "cxdb.sh:       qa/cxdb/cxdb.sh ($([ -x qa/cxdb/cxdb.sh ] && echo ok || echo FIXED))"
echo "App bundle:    $(find .derivedData/Build/Products -name 'Convos.app' -type d | head -1 || echo 'NOT BUILT — run /run first')"
echo ""
echo "Tests found:   $(ls qa/tests/structured/*.yaml | wc -l) YAMLs in qa/tests/structured/"
echo "Budget:        ~$(grep -h '^estimated_duration_s:' qa/tests/structured/*.yaml | awk '{s+=$2} END{print int(s/60)}') min estimated, ~$(grep -h '^estimated_duration_s:' qa/tests/structured/*.yaml | awk '{s+=$2} END{print int(s*2/60)}') min watchdog budget (2× safety)"
echo ""
echo "Would dispatch (default fanout):"
echo "  [A] test 13 (migration) on an isolated simulator"
echo "  [B] main sequence on $UDID (skip 13)"
echo ""
echo "Active CXDB run: $($CXDB active-run || echo none)"
echo "Pending in that run: $(ALL=$(ls qa/tests/structured/ | grep -oE '^[0-9]+[a-z]?' | sort -u | paste -sd,); [ -n \"$($CXDB active-run)\" ] && $CXDB pending-tests $($CXDB active-run) \"$ALL\" | wc -l || echo n/a)"
```

If any prerequisite check in step 2a failed, the dry-run surfaces exactly what's missing and exits non-zero without starting anything.

## Ordering and parallelism

The canonical order (from `qa/SKILL.md` "Run all tests") is:

```
13 → 01 → 12 → 03 → 04 → 02 → 21 → 05 → 06 → 07 → 08 → 09 → 10 → 11
   → 16 → 17 → 20 → 27 → 28 → 19 → 15 → 34 → 18
```

plus secondary tests `14, 22, 23, 23b, 24, 25, 26, 28b, 29, 30, 31, 32, 33` slotted where they don't conflict with destructive steps (09, 18).

**What can actually run in parallel:**

- **Test 13 (migration)** — creates its own isolated simulator and worktree. Always safe to run alongside the main sequence.
- **Tests 03 / 04** — clone a second simulator internally during the test; do *not* launch them in parallel with each other or with 13 (risk of resource contention), but they're fine in the main sequence.
- **Everything else** — shares state (`shared_conversation_id` in CXDB run_state, destructive steps like 09/18) and must stay sequential on the primary simulator.

**Default fanout** (unless `--sequential`): dispatch **2 concurrent** `qa-runner` subagents:

- Agent A: test 13 on its own simulator (the agent creates it per the YAML).
- Agent B: the main sequence on the primary UDID, in the order above (skipping 13).

Do not spawn more than this — additional agents will fight over the primary simulator and CXDB rows.

For `/qa <id>` with a single id: just dispatch one agent — no parallelism needed.

## Expected durations

Per-test budgets come from each YAML's `estimated_duration_s`. The real-world factor tends to be 1.5–1.6× the estimate (based on run `b552ccce49c3`: 115 min estimated, 185 min actual including all chunks + migration). The watchdog's 2× safety factor accounts for this.

**Full suite:** ~2 hours estimated, **2.5–3 hours actual** wall-clock (including build, install, per-test setup/teardown, CLI sync, and inter-test navigation).

**Quickest tests** (< 2 min): 15-performance, 17-swipe-actions, 18-delete, 22-rejoin, 25-baseline, 25b-defaults, 26-failed-send, 29-typing, 31-convos-button.

**Slowest tests** (≥ 5 min estimated): 13-migration (10m — runs on isolated sim, parallelizable), 27-video, 03-invite-deep-link, 05-reactions, 15-performance, 20-photos, 21-gestures, 28-files, 35-identity.

If a single chunk's runner exceeds `sum(estimated_duration_s) × 2` minutes with no CXDB progress (see **Watchdogging runners** below), treat it as hung.

## Dispatching a qa-runner

For each chunk, send an `Agent` call with `subagent_type: qa-runner`. The prompt must include `test_ids` (a single id or an ordered list), `run_id`, and the `udid` the runner should target. The runner iterates the list in order, sharing simulator state and CXDB `_run` state across the chunk.

Example prompt shape:

```
You are executing QA test(s) <ids> for run <run_id>.

Inputs:
- test_ids: ["<id1>", "<id2>", ...]    # or a single "<id>"
- run_id: "<run>"
- udid: "<UDID>"
- simulator_name: "<name>"

Follow the instructions in your agent definition. For each id, read
qa/tests/structured/<id>-*.yaml, translate actions via qa/TOOLS-CLAUDE.md,
record everything to CXDB, then move to the next. Return the compact chunk
summary when done.
```

Default: one runner instance per contiguous chunk of tests that share simulator state. Migration (test 13) is always its own runner on an isolated simulator.

## Watchdogging runners

The `Agent` tool has no native timeout. You must budget wall-clock time per chunk and intervene if a runner goes dark.

1. **Budget** = sum of each test's `estimated_duration_s` (from the YAML) × **2.0** safety factor. A chunk of tests with estimated_duration_s totaling 1500s gets a 3000s (50 min) budget.
2. **Dispatch in background** — always use `run_in_background: true` on the `Agent` call so the orchestrator can make other decisions while waiting.
3. **Progress probe** — roughly every 10 minutes of wall-clock, query CXDB for progress:
   ```bash
   # What tests have finished in this run recently?
   $CXDB sql "SELECT test_id, status, finished_at FROM test_results WHERE run_id='$RUN' AND finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT 5;"
   # What's currently running?
   $CXDB sql "SELECT test_id, started_at FROM test_results WHERE run_id='$RUN' AND status='running';"
   ```
   If `finished_at` of the latest completed test is within the last 10 min, the runner is alive — keep waiting.
4. **On budget exceeded** — check CXDB once more. If there's been no progress (no new `finished_at` rows) for a full budget window, the runner is likely stuck. Cancel it (via the sub-agent management flow), mark any `running` test_results as `error` with note "orchestrator timeout", and decide whether to retry or skip to the next chunk.
5. **Do not poll more than every ~5 minutes** — each CXDB query is cheap but polling also incurs tokens and you'll get a completion notification when the agent returns naturally.

If you kill a runner, the `_run` state in CXDB remains intact. You can re-dispatch a new runner for the remaining `pending-tests` without losing the conversation IDs, identities, or app state the killed runner established.

## After all runners complete

1. **Finish the run.** `$CXDB finish-run "$RUN"` — derives status from test results.
2. **Render the report.** `$CXDB report-md "$RUN" > qa/reports/run-$RUN.md`.
3. **Print the summary to chat.**
   ```bash
   $CXDB summary "$RUN"
   ```
   Then a short narrative: overall status, headline failures, any new bugs/accessibility findings. Point the user at `qa/reports/run-$RUN.md` for the full report.

## `/qa list`

```bash
CXDB=qa/cxdb/cxdb.sh
RUN=$($CXDB active-run)
if [ -z "$RUN" ]; then echo "No active run. Start one with /qa."; exit 0; fi

ALL_IDS=$(ls qa/tests/structured/ | grep -oE '^[0-9]+[a-z]?' | sort -u | paste -sd,)
$CXDB pending-tests "$RUN" "$ALL_IDS"
```

Print the pending list plus a status table pulled from CXDB.

## `/qa report`

```bash
CXDB=qa/cxdb/cxdb.sh
RUN=$($CXDB history 1 | awk 'NR==2 {print $1}')
$CXDB report-md "$RUN" > qa/reports/run-$RUN.md
$CXDB summary "$RUN"
```

Then show the path to the rendered report.

## Failure modes to handle

- **Docker not running** → most integration tests are fine (they talk to the `dev` XMTP network, not local Docker), but `convos init` may need it for some commands. Follow `CLAUDE.md` guidance.
- **App crashes mid-test** → the runner records the failure, finishes the test as `error`, and the orchestrator (this command) continues with the next test. Do not stop the whole run unless 3+ tests error in a row.
- **Build fails** → do not start any runners. Report the build error and stop.
- **Simulator unresponsive** → try `xcrun simctl shutdown "$UDID" && xcrun simctl boot "$UDID"` and relaunch once. If that fails, stop.
