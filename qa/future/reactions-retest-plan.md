# Reactions Codec v2 Retest Plan

## Goal
Re-run the full QA test suite on the `claude-code-qa` branch with reactions codec v2 merged from dev. Test focus on **Test 05 (Reactions)** which previously failed due to CLI reactions not appearing in the app.

## Setup Done
- ✅ Branch rebased on dev (reactions codec v2 @ commit `0003f5cf` already in history)
- ✅ CLI reset with `convos reset`
- ✅ CXDB infrastructure created: `qa/cxdb/qa.sqlite` ready
- ✅ CXDB run created: `c425de02bf1f` 
- ✅ App rebuilt with dev environment
- ✅ Initial log marker captured: `2026-02-13T16:17:04Z`
- ❌ Agent Server startup needs resolution (xcodebuild process exited)

## Known Working Infrastructure

1. **CXDB commands** (tested):
   ```bash
   cxdb.sh new-run <udid> <commit> [device] [notes]
   cxdb.sh start-test <run_id> <test_id> <name>
   cxdb.sh finish-test <result_id> <status> "" <notes>
   cxdb.sh log-error <run_id> <test_id> <ts> <src> <msg> <is_xmtp:0|1>
   ```

2. **Log capture** (via ios-simulator-mcp):
   ```bash
   sim_log_tail --lines 50 --level warning+error
   ```

3. **Pi extensions** (all working):
   - `sim_wait_and_tap`, `sim_find_elements`, `sim_observe`, `sim_chain`
   - Performance: p50 tap ~1.5s, observe ~0.9-2.7s, chain ~5s for 3 steps

## Next Steps

### 1. Restart Agent Server Robustly
```bash
# Start fresh with explicit wait
pkill -f "AgentServer" || true
cd /path/to/convos-ios
xcodebuild test-without-building -scheme "AgentServer" \
  -destination "id=57F6DAD0-4A9C-4CDF-BE00-4BFE2E54BDFB" \
  -derivedDataPath .derivedData -configuration Dev \
  -only-testing:AgentServer/AgentServerTest/testAgentServer \
  &> /tmp/agent-server.log &

# Poll with timeout
for i in {1..60}; do
  if curl -s -X POST http://localhost:8615/action \
    -H 'Content-Type: application/json' -d '{"action":"ping"}' \
    2>/dev/null | jq .success 2>/dev/null | grep -q true; then
    echo "Agent Server ready"
    break
  fi
  sleep 1
done
```

### 2. Run Test 05 (Reactions) — Focus Test
With reactions codec v2 merged, CLI reactions should now appear in the app.

**Expected changes:**
- CLI reactions should be visible in app (was failing before)
- App reactions should be queryable via CLI
- Multiple reactions on same message should display correctly

**Test flow:**
1. Reset CLI: `convos reset`
2. Create conversation from CLI
3. Send text message from CLI
4. React from CLI with `👍`
5. Verify reaction appears in app ⬅️ **KEY TEST CHANGE**
6. Double-tap to react from app
7. Verify via CLI

### 3. Log Capture Strategy
For each test:
```bash
# At end of test:
sim_log_tail --lines 100 --level warning+error > /tmp/logs-test-<id>.txt

# Process errors:
while read line; do
  cxdb.sh log-error "$RUN_ID" "$test_id" "$ts" "$src" "$msg" "$is_xmtp"
done < /tmp/logs-test-<id>.txt
```

### 4. Full Suite Timeline
- Test 01: Onboarding (fresh app state from delete)
- Test 02: Send/Receive Messages
- Test 03: Deep Link Join
- **Test 05: Reactions** (focus test with v2 codec)
- Test 06: Replies
- Test 07: Profile Update
- Test 08: Lock Conversation (may have state sync issue)
- Test 09: Explode Conversation
- Test 10: Pin Conversation
- Test 11: Mute Conversation
- Test 12: Create from App
- Test 16: Conversation Filters
- Test 17: Swipe Actions
- Test 18: Delete All Data

## CXDB Report Generation
At end of run:
```bash
cxdb.sh finish-run "c425de02bf1f"
cxdb.sh report-md "c425de02bf1f" > qa/reports/reactions-retest-<date>.md
```

Will automatically generate markdown summary with:
- Pass/fail counts
- Per-test criteria tracking
- Error log summary
- Performance metrics if recorded

## Success Criteria
- ✅ Reactions codec v2 is working
- ✅ CLI reactions now appear in app (main test target)
- ✅ App reactions queryable from CLI  
- ✅ Full suite runs with <2s per interaction
- ✅ Errors captured to CXDB and summarized
