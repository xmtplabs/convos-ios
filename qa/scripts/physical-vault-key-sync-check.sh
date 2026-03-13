#!/usr/bin/env bash
set -euo pipefail

DEVICE_INPUT="${1:-10u15-mini}"
BUNDLE_ID="${BUNDLE_ID:-org.convos.ios-preview}"
REPORT_DIR="${REPORT_DIR:-qa/reports}"

mkdir -p "$REPORT_DIR"

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
LOG_FILE="$REPORT_DIR/physical-vault-key-sync-$TIMESTAMP.log"
REPORT_FILE="$REPORT_DIR/physical-vault-key-sync-$TIMESTAMP.md"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1"
        exit 1
    fi
}

resolve_udid() {
    local input="$1"

    if [[ "$input" =~ ^[0-9A-Fa-f-]{25,}$ ]]; then
        if ideviceinfo -u "$input" -k DeviceName >/dev/null 2>&1; then
            echo "$input"
            return 0
        fi
    fi

    while read -r candidate_udid; do
        [[ -z "$candidate_udid" ]] && continue
        local candidate_name
        candidate_name="$(ideviceinfo -u "$candidate_udid" -k DeviceName 2>/dev/null || true)"
        if [[ "$candidate_name" == "$input" ]]; then
            echo "$candidate_udid"
            return 0
        fi
    done < <(idevice_id -l)

    return 1
}

bootstrap_count() {
    local count
    count="$(grep -c "Vault bootstrapped: inboxId=" "$LOG_FILE" 2>/dev/null || true)"
    count="$(echo "$count" | tail -1 | tr -dc '0-9')"

    if [[ -z "$count" ]]; then
        echo 0
    else
        echo "$count"
    fi
}

latest_bootstrap_inbox_id() {
    grep "Vault bootstrapped: inboxId=" "$LOG_FILE" 2>/dev/null | tail -1 | sed -E 's/.*inboxId=([^ ]+).*/\1/'
}

wait_for_new_bootstrap() {
    local previous_count="$1"
    local timeout_seconds="$2"
    local description="$3"
    local start
    local last_reported_seconds=-1
    start="$(date +%s)"

    echo "Waiting for $description log signal (up to ${timeout_seconds}s)..."

    while true; do
        local current_count
        current_count="$(bootstrap_count)"

        if (( current_count > previous_count )); then
            echo "Detected new vault bootstrap log entry."
            return 0
        fi

        local elapsed
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_seconds )); then
            echo "No new vault bootstrap log entry seen within ${timeout_seconds}s."
            return 1
        fi

        if (( elapsed > 0 && elapsed % 10 == 0 && elapsed != last_reported_seconds )); then
            echo "  ... still waiting (${elapsed}s/${timeout_seconds}s)"
            last_reported_seconds=$elapsed
        fi

        sleep 1
    done
}

is_app_installed() {
    local tmp_json
    tmp_json="$(mktemp /tmp/devicectl-apps.XXXX.json)"

    if ! xcrun devicectl device info apps --device "$DEVICE_INPUT" --bundle-id "$BUNDLE_ID" --json-output "$tmp_json" >/dev/null 2>&1; then
        rm -f "$tmp_json"
        return 1
    fi

    local installed
    installed="$(python3 - "$tmp_json" 2>/dev/null <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    payload = json.load(f)

apps = payload.get("result", {}).get("apps", [])
print("1" if apps else "0")
PY
)"

    rm -f "$tmp_json"
    [[ "$installed" == "1" ]]
}

find_device_app_bundle() {
    find .derivedData/Build/Products -path '*-iphoneos/Convos.app' -type d 2>/dev/null | head -1
}

launch_app() {
    local tmp_json
    tmp_json="$(mktemp /tmp/devicectl-launch.XXXX.json)"

    set +e
    xcrun devicectl device process launch \
        --device "$DEVICE_INPUT" \
        --terminate-existing \
        "$BUNDLE_ID" \
        --json-output "$tmp_json" >/dev/null 2>&1
    local exit_code=$?
    set -e

    if (( exit_code != 0 )); then
        local reason
        reason="$(python3 - "$tmp_json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        payload = json.load(f)
except Exception:
    print("unknown launch error")
    raise SystemExit

user_info = payload.get("error", {}).get("userInfo", {})
failure_reason = user_info.get("NSLocalizedFailureReason", {}).get("string")
description = user_info.get("NSLocalizedDescription", {}).get("string")
print(failure_reason or description or "unknown launch error")
PY
)"
        echo "Warning: automatic app launch failed: $reason"
        echo "Please open Convos manually on your iPhone."
    fi

    rm -f "$tmp_json"
}

print_step() {
    local title="$1"
    local body="$2"

    echo
    echo "== $title =="
    printf "%b\n" "$body"
    echo
    read -r -p "Press Enter when done... "
}

require_command idevice_id
require_command ideviceinfo
require_command idevicesyslog
require_command xcrun
require_command python3
require_command stdbuf

UDID="$(resolve_udid "$DEVICE_INPUT" || true)"
if [[ -z "$UDID" ]]; then
    echo "Could not find a connected device matching '$DEVICE_INPUT'."
    echo "Try one of these names from: xcrun devicectl list devices"
    exit 1
fi

DEVICE_NAME="$(ideviceinfo -u "$UDID" -k DeviceName 2>/dev/null || echo "$DEVICE_INPUT")"
DEVICE_VERSION="$(ideviceinfo -u "$UDID" -k ProductVersion 2>/dev/null || echo "unknown")"

echo "Using device: $DEVICE_NAME ($UDID)"
echo "iOS version: $DEVICE_VERSION"

if ! is_app_installed; then
    echo
    echo "App $BUNDLE_ID is not installed on this device."

    APP_PATH="$(find_device_app_bundle || true)"
    if [[ -n "$APP_PATH" ]]; then
        echo "Found a built device app at: $APP_PATH"
        echo "Attempting to install it..."

        if ! xcrun devicectl device install app --device "$DEVICE_INPUT" "$APP_PATH" >/dev/null 2>&1; then
            echo "Install failed. Please run the app once from Xcode, then re-run this script."
            exit 1
        fi

        echo "Install succeeded."
    else
        echo "No device build found under .derivedData."
        echo "Run the app once from Xcode on this device (or build+install), then re-run this script."
        echo "Suggested build command:"
        echo "  xcodebuild build -project Convos.xcodeproj -scheme \"Convos (Dev)\" -destination \"id=$UDID\" -derivedDataPath .derivedData"
        exit 1
    fi
fi

echo "Saving raw logs to: $LOG_FILE"

stdbuf -oL idevicesyslog -u "$UDID" --no-colors > "$LOG_FILE" 2>&1 &
LOG_PID=$!

cleanup() {
    if [[ -n "${LOG_PID:-}" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
        kill "$LOG_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

sleep 2
launch_app

first_before_count="$(bootstrap_count)"
print_step \
    "Step 1/2 — Initial app run" \
    "On your iPhone:\n1. Open Convos.\n2. If onboarding/login appears, complete it until you reach the conversations/home screen.\n3. Keep the app in the foreground for ~10 seconds."

if wait_for_new_bootstrap "$first_before_count" 120 "initial vault bootstrap"; then
    FIRST_INBOX_ID="$(latest_bootstrap_inbox_id)"
elif (( first_before_count > 0 )); then
    FIRST_INBOX_ID="$(latest_bootstrap_inbox_id)"
    echo "Using existing vault bootstrap log entry from this run."
else
    FIRST_INBOX_ID=""
fi

second_before_count="$(bootstrap_count)"
print_step \
    "Step 2/2 — Relaunch check" \
    "On your iPhone:\n1. Open app switcher and force-close Convos.\n2. Reopen Convos from the home screen.\n3. Keep it in the foreground for ~10 seconds."

if wait_for_new_bootstrap "$second_before_count" 120 "post-relaunch vault bootstrap"; then
    SECOND_INBOX_ID="$(latest_bootstrap_inbox_id)"
else
    SECOND_INBOX_ID=""
fi

ICLOUD_SYNC_LINES="$(grep 'iCloud key sync:' "$LOG_FILE" 2>/dev/null || true)"
ICLOUD_FAILURE_LINES="$(grep -E 'Failed to save identity to iCloud Keychain|Failed to sync key to iCloud|Keychain format migration: failed' "$LOG_FILE" 2>/dev/null || true)"

STATUS="PASS"
if [[ -z "$FIRST_INBOX_ID" ]]; then
    STATUS="CHECK_MANUALLY"
fi
if [[ -z "$SECOND_INBOX_ID" ]]; then
    STATUS="CHECK_MANUALLY"
fi
if [[ -n "$FIRST_INBOX_ID" && -n "$SECOND_INBOX_ID" && "$FIRST_INBOX_ID" != "$SECOND_INBOX_ID" ]]; then
    STATUS="FAIL"
fi
if [[ -n "$ICLOUD_FAILURE_LINES" ]]; then
    STATUS="FAIL"
fi

{
    echo "# Physical Device Vault Key Sync Check"
    echo
    echo "- Device: $DEVICE_NAME"
    echo "- UDID: $UDID"
    echo "- iOS: $DEVICE_VERSION"
    echo "- Bundle ID: $BUNDLE_ID"
    echo "- Timestamp: $(date)"
    echo "- Status: $STATUS"
    echo
    echo "## Signals"
    echo "- First bootstrap inboxId: ${FIRST_INBOX_ID:-<not found>}"
    echo "- Second bootstrap inboxId: ${SECOND_INBOX_ID:-<not found>}"
    echo
    echo "## iCloud Sync Logs"
    if [[ -n "$ICLOUD_SYNC_LINES" ]]; then
        echo '```'
        echo "$ICLOUD_SYNC_LINES"
        echo '```'
    else
        echo "No explicit 'iCloud key sync: copied ...' lines found."
    fi
    echo
    echo "## iCloud Failure Logs"
    if [[ -n "$ICLOUD_FAILURE_LINES" ]]; then
        echo '```'
        echo "$ICLOUD_FAILURE_LINES"
        echo '```'
    else
        echo "None found."
    fi
    echo
    echo "## Raw Logs"
    echo "$LOG_FILE"
} > "$REPORT_FILE"

echo
echo "Done."
echo "Status: $STATUS"
echo "Report: $REPORT_FILE"
echo "Raw logs: $LOG_FILE"

if [[ "$STATUS" == "FAIL" ]]; then
    exit 2
fi
