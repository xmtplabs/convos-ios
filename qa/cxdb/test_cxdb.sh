#!/bin/bash
# Smoke tests for cxdb.sh — verifies every command round-trips through the schema.
# Usage: ./qa/cxdb/test_cxdb.sh
# Runs against a throwaway DB in a temp dir, never touches qa/cxdb/qa.sqlite.

set -u   # not -e — we want to keep going past individual failures to report totals

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_CXDB="$SCRIPT_DIR/cxdb.sh"

# Relocate the DB for this test run. cxdb.sh computes DB path from its own
# directory, so copy it + schema into a temp dir to isolate.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$SCRIPT_DIR/cxdb.sh" "$TMP_DIR/cxdb.sh"
cp "$SCRIPT_DIR/schema.sql" "$TMP_DIR/schema.sql"
chmod +x "$TMP_DIR/cxdb.sh"

CXDB="$TMP_DIR/cxdb.sh"
PASS=0
FAIL=0
FAILED_TESTS=()

check() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf "  \033[0;32m✓\033[0m %s\n" "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf "  \033[0;31m✗\033[0m %s\n" "$name"
        printf "    expected: %s\n" "$expected"
        printf "    actual:   %s\n" "$actual"
    fi
}

check_contains() {
    local name="$1"
    local haystack="$2"
    local needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf "  \033[0;32m✓\033[0m %s\n" "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf "  \033[0;31m✗\033[0m %s\n" "$name"
        printf "    '%s' not found in output:\n%s\n" "$needle" "$haystack"
    fi
}

echo "=== cxdb.sh smoke tests ==="
echo "tmp dir: $TMP_DIR"
echo

# -----------------------------------------------------------------------------
echo "## Run lifecycle (new-run, active-run, finish-run, history)"
RUN=$("$CXDB" new-run "UDID-FAKE-001" "abc1234" "iPhone 16 Pro" "smoke test run" 2>/dev/null)
check "new-run returns 12-char id" "${#RUN}" "12"

ACTIVE=$("$CXDB" active-run 2>/dev/null)
check "active-run returns the new run while it's running" "$ACTIVE" "$RUN"

# -----------------------------------------------------------------------------
echo
echo "## Test lifecycle (start-test, test-status, record-criterion, finish-test)"
TR=$("$CXDB" start-test "$RUN" "99" "Smoke Test 99" 2>/dev/null)
check "start-test returns a result id" "${#TR}" "12"

STATUS=$("$CXDB" test-status "$RUN" "99" 2>/dev/null)
check "test-status during run reads 'running'" "$STATUS" "running"

"$CXDB" record-criterion "$TR" "crit_a" "pass" "First criterion" "evidence A" >/dev/null 2>&1
"$CXDB" record-criterion "$TR" "crit_b" "fail" "Second criterion" "evidence B" >/dev/null 2>&1

"$CXDB" finish-test "$TR" "fail" "second criterion failed" "some notes" >/dev/null 2>&1
STATUS2=$("$CXDB" test-status "$RUN" "99" 2>/dev/null)
check "test-status after finish reads 'fail'" "$STATUS2" "fail"

# -----------------------------------------------------------------------------
echo
echo "## pending-tests filters out completed ids"
PENDING=$("$CXDB" pending-tests "$RUN" "99,100,101" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
# Fail != done: pending-tests only excludes pass/skip. 99 finished 'fail' above so it
# stays pending, alongside the untouched 100 and 101. This lets failed tests be retried.
check "pending-tests treats fail as not-done; all three stay pending" "$PENDING" "99,100,101"

TR2=$("$CXDB" start-test "$RUN" "100" "Smoke Test 100" 2>/dev/null)
"$CXDB" record-criterion "$TR2" "crit_ok" "pass" "All good" "evidence" >/dev/null 2>&1
"$CXDB" finish-test "$TR2" "pass" >/dev/null 2>&1
PENDING2=$("$CXDB" pending-tests "$RUN" "99,100,101" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
check "pending-tests excludes 100 after it passed" "$PENDING2" "99,101"

# -----------------------------------------------------------------------------
echo
echo "## State (set-state / get-state / all-state)"
"$CXDB" set-state "$RUN" "99" "conversation_id" "abc-123" >/dev/null 2>&1
"$CXDB" set-state "$RUN" "_run" "shared_conversation_id" "shared-xyz" >/dev/null 2>&1
"$CXDB" set-state "$RUN" "99" "msg_id" "m-42" >/dev/null 2>&1

TEST_STATE=$("$CXDB" get-state "$RUN" "99" "conversation_id" 2>/dev/null)
check "get-state test-level read" "$TEST_STATE" "abc-123"

RUN_STATE=$("$CXDB" get-state "$RUN" "_run" "shared_conversation_id" 2>/dev/null)
check "get-state _run-level read" "$RUN_STATE" "shared-xyz"

ALL_STATE=$("$CXDB" all-state "$RUN" 2>/dev/null)
check_contains "all-state shows run-level keys" "$ALL_STATE" "shared_conversation_id"
check_contains "all-state shows test-level keys" "$ALL_STATE" "conversation_id"
check_contains "all-state shows test msg_id" "$ALL_STATE" "m-42"

# set-state overwrite
"$CXDB" set-state "$RUN" "99" "conversation_id" "abc-123-updated" >/dev/null 2>&1
TEST_STATE2=$("$CXDB" get-state "$RUN" "99" "conversation_id" 2>/dev/null)
check "set-state overwrites existing key" "$TEST_STATE2" "abc-123-updated"

# -----------------------------------------------------------------------------
echo
echo "## Logging (log-error, log-event, log-bug, log-a11y, log-perf)"
"$CXDB" log-error "$RUN" "99" "2026-04-23T12:00:00Z" "ConvosCore" "nil deref in Foo.swift" "0" >/dev/null 2>&1
"$CXDB" log-error "$RUN" "99" "2026-04-23T12:00:05Z" "XMTPiOS" "[GroupError::Sync] transient" "1" >/dev/null 2>&1

# Raw sql readback
ERRS=$("$CXDB" sql "SELECT COUNT(*) FROM log_entries WHERE run_id='$RUN'" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-error writes rows" "$ERRS" "2"

APP_ERRS=$("$CXDB" sql "SELECT COUNT(*) FROM log_entries WHERE run_id='$RUN' AND is_app_error=1" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-error is_xmtp=0 flips is_app_error=1" "$APP_ERRS" "1"

XMTP_ERRS=$("$CXDB" sql "SELECT COUNT(*) FROM log_entries WHERE run_id='$RUN' AND is_xmtp_error=1" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-error is_xmtp=1 sets is_xmtp_error=1" "$XMTP_ERRS" "1"

"$CXDB" log-event "$RUN" "99" "2026-04-23T12:01:00Z" "message.sent" '{"id":"abc","conversation":"xyz"}' >/dev/null 2>&1
"$CXDB" log-event "$RUN" "99" "2026-04-23T12:01:05Z" "message.received" '{"id":"def"}' >/dev/null 2>&1

EVENTS=$("$CXDB" events "$RUN" 2>/dev/null)
check_contains "events shows message.sent" "$EVENTS" "message.sent"
check_contains "events shows message.received" "$EVENTS" "message.received"

EVENTS_FILTERED=$("$CXDB" events "$RUN" "99" "message.sent" 2>/dev/null)
check_contains "events with test_id + pattern filters to message.sent" "$EVENTS_FILTERED" "message.sent"

"$CXDB" log-bug "$RUN" "99" "major" "Null pointer in login" "Crash when email is empty" >/dev/null 2>&1
BUG_COUNT=$("$CXDB" sql "SELECT COUNT(*) FROM bug_findings WHERE run_id='$RUN'" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-bug writes a row" "$BUG_COUNT" "1"

"$CXDB" log-a11y "$RUN" "99" "compose-button in bottom toolbar" "add accessibilityIdentifier" >/dev/null 2>&1
A11Y_COUNT=$("$CXDB" sql "SELECT COUNT(*) FROM accessibility_findings WHERE run_id='$RUN'" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-a11y writes a row" "$A11Y_COUNT" "1"

"$CXDB" log-perf "$RUN" "99" "open_few_msgs" "45" "50" >/dev/null 2>&1
"$CXDB" log-perf "$RUN" "99" "open_many_msgs" "120" "50" >/dev/null 2>&1
PERF_PASSED=$("$CXDB" sql "SELECT COUNT(*) FROM perf_measurements WHERE run_id='$RUN' AND passed=1" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-perf marks passed=1 when value<=target" "$PERF_PASSED" "1"
PERF_FAILED=$("$CXDB" sql "SELECT COUNT(*) FROM perf_measurements WHERE run_id='$RUN' AND passed=0" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "log-perf marks passed=0 when value>target" "$PERF_FAILED" "1"

# -----------------------------------------------------------------------------
echo
echo "## Reporting (summary, report-md, history)"
SUMMARY=$("$CXDB" summary "$RUN" 2>/dev/null)
check_contains "summary shows the run id" "$SUMMARY" "$RUN"
check_contains "summary shows test 99" "$SUMMARY" "99"
check_contains "summary shows test 100" "$SUMMARY" "100"
check_contains "summary counts bugs" "$SUMMARY" "Bugs: 1"

REPORT=$("$CXDB" report-md "$RUN" 2>/dev/null)
check_contains "report-md includes summary table" "$REPORT" "| Test | Status"
check_contains "report-md renders pass checkbox" "$REPORT" "- [x] First criterion"
check_contains "report-md renders fail marker" "$REPORT" "**FAIL:**"
check_contains "report-md Bugs Found section" "$REPORT" "Bugs Found"
check_contains "report-md Accessibility Improvements Needed section" "$REPORT" "Accessibility Improvements Needed"
check_contains "report-md Performance section" "$REPORT" "Performance"

HISTORY=$("$CXDB" history 5 2>/dev/null)
check_contains "history lists the run" "$HISTORY" "$RUN"

# -----------------------------------------------------------------------------
echo
echo "## finish-run derives status"
"$CXDB" finish-run "$RUN" >/dev/null 2>&1
FINAL_STATUS=$("$CXDB" sql "SELECT status FROM test_runs WHERE id='$RUN'" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
# One fail, one pass → "failed" per the script logic
check "finish-run status='failed' with 1 fail + 1 pass" "$FINAL_STATUS" "failed"

# -----------------------------------------------------------------------------
echo
echo "## compare (regression/fix detection)"
RUN_OLD="$RUN"
RUN_NEW=$("$CXDB" new-run "UDID-FAKE-002" "def5678" "iPhone" "compare test" 2>/dev/null)
# 99 was fail in old run → pass in new run (fix)
TR_N=$("$CXDB" start-test "$RUN_NEW" "99" "Smoke Test 99" 2>/dev/null)
"$CXDB" finish-test "$TR_N" "pass" >/dev/null 2>&1
# 100 was pass in old → fail in new (regression)
TR_N2=$("$CXDB" start-test "$RUN_NEW" "100" "Smoke Test 100" 2>/dev/null)
"$CXDB" finish-test "$TR_N2" "fail" >/dev/null 2>&1

CMP=$("$CXDB" compare "$RUN_OLD" "$RUN_NEW" 2>/dev/null)
check_contains "compare lists test 100 as regression (passed → failed)" "$CMP" "100"
check_contains "compare lists test 99 as fix (failed → passed)" "$CMP" "99"

# -----------------------------------------------------------------------------
echo
echo "## reset"
"$CXDB" reset 2>/dev/null >/dev/null
POST_RESET=$("$CXDB" sql "SELECT COUNT(*) FROM test_runs" 2>/dev/null | awk 'NR>=3 {print $1}' | head -1)
check "reset wipes all runs" "$POST_RESET" "0"

# -----------------------------------------------------------------------------
echo
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "  Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "    - $t"
    done
    exit 1
fi

echo
echo "✅ All checks passed"
