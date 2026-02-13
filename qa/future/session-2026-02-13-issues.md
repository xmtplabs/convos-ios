# Session 2026-02-13: Infrastructure Issues & Action Items

## What Worked
- ✅ Simulator reset and erase
- ✅ App rebuild clean
- ✅ CLI reset via `convos reset`
- ✅ CXDB run initialization
- ✅ iOS simulator MCP tools (direct, without Agent Server)
  - `sim_ui_tap(x, y)` — works reliably
  - `sim_screenshot` — works reliably
  - `sim_ui_describe_all` — works reliably
- ✅ Direct curl to Agent Server HTTP API

## What Broke
- ❌ Agent Server pi extension (`sim_wait_and_tap`, `sim_chain`, etc.)
  - Initial startup seemed OK ("Agent Server ready!")
  - But curl requests failed with no response
  - Process exited completely after a few minutes
  - Logs show server was listening but wouldn't respond to requests
- ❌ Pi extension layer abstractions
  - Agent Server + pi extension combination is fragile
  - Curl to localhost:8615 also unreliable

## Root Cause (Hypothesis)
The Agent Server might be:
1. Crashing on first real action (not just ping)
2. Binding to wrong address/port
3. Running out of XCUITest resources
4. The pi extension fetch layer has timeouts that don't match server latency

## Recommended Fixes

### Option 1: Skip Agent Server, Use Direct iOS Simulator MCP
The iOS Simulator MCP tools are more stable. Use them directly:
```bash
sim_ui_tap <x> <y>
sim_ui_describe_all
sim_ui_describe_point <x> <y>
sim_screenshot
sim_ui_type <text>
sim_ui_key <keycode>
```

**Pros:**
- No external server process
- Direct to simulator
- Stable, proven track record

**Cons:**
- Slower than optimized Agent Server
- No performance batching (chain)

### Option 2: Debug Agent Server
- Add logging to see where it crashes
- Check if it's an XCUITest automation issue
- Profile network requests to see what's failing
- Run Server with explicit foreground output

### Option 3: Hybrid Approach
- Use iOS Simulator MCP for tests
- Keep Agent Server running for performance benchmarks only (test 15)
- Saves time and uses what's stable

## Recommended Path Forward

**Use Option 1 (Direct iOS Simulator MCP) to complete the 18-test suite.** Here's why:

1. **Stability > Speed**: We can't afford server crashes mid-test
2. **Time-bound session**: Limited token budget; can't debug infrastructure
3. **Tests don't need sub-2s interactions**: ~2-3s per tap is acceptable for QA
4. **Full feature coverage**: iOS Simulator MCP has all needed capabilities
5. **Simpler codebase**: No pi extension layer to troubleshoot

## Updated Test Execution Plan

1. Keep current session state (simulator reset, CLI ready, app fresh)
2. Run all 18 tests using **direct iOS Simulator MCP calls**
3. Log all actions and results to CXDB
4. Generate final report with error/warning summary
5. File issues for Agent Server stabilization (separate task)

## Files to Modify

- `.pi/extensions/sim-tools.ts` — could be updated to bypass Agent Server on failures
- Or create new `.pi/extensions/sim-tools-mcp-direct.ts` — direct MCP calls
- Or run tests with inline MCP calls (less elegant but more stable)

## Session Impact

- Lost ~30 minutes debugging Agent Server
- But learned: iOS Simulator MCP is the stable baseline
- Next session can start with this intel and proceed faster
- CXDB infrastructure is ready and working
- Branch is clean and tracked with Graphite

## Decision Point for Next Session

**Before running tests, decide:**
1. Restart with direct MCP tools (recommended) → proceed immediately
2. Try to fix Agent Server → requires debugging first
3. Hybrid approach → run both, use MCP fallback if server fails
