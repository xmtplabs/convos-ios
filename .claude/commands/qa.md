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

## Before dispatching

1. **Read the playbook** if this is the first `/qa` call in the session:
   - `qa/RULES.md` — the contract (Read-Only Policy, log monitoring, ephemeral UI, multi-simulator, pasteboard safety, no-sleep, etc.).
   - `qa/TOOLS-CLAUDE.md` — pi `sim_*` vocabulary → Claude MCP / Bash mapping. **Always use this when translating YAML actions.**
   - `qa/tests/structured/README.md` — action/verify/criteria semantics.
2. **Resolve the primary simulator UDID.** Read `.claude/.simulator_id`. If missing, fall back to `.convos-task` `SIMULATOR_NAME` or derive from `git branch --show-current` per `qa/RULES.md` "Simulator Selection", then resolve via `xcrun simctl list devices -j`. If the simulator doesn't exist, run `/setup` first and abort.
3. **Verify the app is running.** Take a quick screenshot. If it isn't, build + install + launch via `.pi/skills/run/SKILL.md` (use `xcodebuild` via Bash — never `mcp__XcodeBuildMCP__build_sim`). This may take a few minutes; report progress.
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

## Dispatching a qa-runner

For each test slot, send an `Agent` call with `subagent_type: qa-runner`. The prompt must include the `test_id`, `run_id`, and the `udid` the runner should target.

Example prompt shape (adapt per test):

```
You are executing QA test <test_id> for run <run_id>.

Inputs:
- test_id: "<id>"
- run_id: "<run>"
- udid: "<UDID>"
- simulator_name: "<name>"  # for error messages

Follow the instructions in your agent definition. Read qa/tests/structured/<id>-*.yaml,
translate actions via qa/TOOLS-CLAUDE.md, record everything to CXDB, and return the
compact summary when done.
```

When running the main sequence on one agent, either:
- pass a list of test IDs in order and let the runner iterate (preferred for long sequences — one agent, one context), or
- call the runner once per test (cleaner isolation but more context switches).

Default: one runner instance per contiguous chunk of tests that share simulator state. Migration is always its own runner.

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
