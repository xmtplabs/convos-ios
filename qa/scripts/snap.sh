#!/bin/bash
# snap.sh -- capture a simulator screenshot into a QA run's artifact directory
# and register it in CXDB so the run artifact's carousel can render it.
#
# Usage: snap.sh <run_id> <test_id> <step_id> <udid> [caption]
#
# Files land in qa/artifacts/run-<run_id>/screenshots/ with a sortable,
# collision-safe name. Images are downscaled (longest edge 900px) to keep
# multi-hour runs from producing hundreds of MB of full-resolution PNGs.
# Prints the absolute path of the captured file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CXDB="$REPO_ROOT/qa/cxdb/cxdb.sh"

RUN_ID="${1:?run_id required}"
TEST_ID="${2:?test_id required}"
STEP_ID="${3:?step_id required}"
UDID="${4:?udid required}"
CAPTION="${5:-}"

SHOT_DIR="$REPO_ROOT/qa/artifacts/run-$RUN_ID/screenshots"
mkdir -p "$SHOT_DIR"

# Sortable timestamp prefix + pid/random suffix: parallel runners (main
# sequence + migration) capture concurrently and must never collide.
TS=$(date -u +%Y%m%dT%H%M%S)
SAFE_STEP=$(printf '%s' "$STEP_ID" | tr -c 'a-zA-Z0-9_-' '-' | cut -c1-48)
FILE="${TS}-${TEST_ID}-${SAFE_STEP}-$$${RANDOM}.png"

xcrun simctl io "$UDID" screenshot "$SHOT_DIR/$FILE" >/dev/null
sips -Z 900 "$SHOT_DIR/$FILE" >/dev/null 2>&1 || echo "warn: sips downscale failed for $FILE (keeping full-size capture)" >&2

[ -x "$CXDB" ] || chmod +x "$CXDB"
"$CXDB" log-screenshot "$RUN_ID" "$TEST_ID" "$STEP_ID" "screenshots/$FILE" "$CAPTION" >/dev/null

echo "$SHOT_DIR/$FILE"
