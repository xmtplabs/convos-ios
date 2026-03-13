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
    grep -c "Vault bootstrapped: inboxId=" "$LOG_FILE" 2>/dev/null || echo 0
}

latest_bootstrap_inbox_id() {
    grep "Vault bootstrapped: inboxId=" "$LOG_FILE" 2>/dev/null | tail -1 | sed -E 's/.*inboxId=([^ ]+).*/\1/'
}

wait_for_new_bootstrap() {
    local previous_count="$1"
    local timeout_seconds="$2"
    local start
    start="$(date +%s)"

    while true; do
        local current_count
        current_count="$(bootstrap_count)"
        if (( current_count > previous_count )); then
            return 0
        fi

        if (( $(date +%s) - start >= timeout_seconds )); then
            return 1
        fi
        sleep 1
    done
}

launch_app() {
    xcrun devicectl device process launch \
        --device "$DEVICE_INPUT" \
        --terminate-existing \
        "$BUNDLE_ID" >/dev/null 2>&1 || true
}

print_step() {
    local title="$1"
    local body="$2"
    echo
    echo "== $title =="
    echo "$body"
    echo
    read -r -p "Press Enter when done... "
}

require_command idevice_id
require_command ideviceinfo
require_command idevicesyslog
require_command xcrun

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

print_step \
    "Step 1/2 — Initial app run" \
    "On your iPhone:\n1. Open Convos.\n2. If onboarding/login appears, complete it until you reach the conversations/home screen.\n3. Keep the app in the foreground for ~10 seconds."

first_before_count="$(bootstrap_count)"
if wait_for_new_bootstrap "$first_before_count" 120; then
    FIRST_INBOX_ID="$(latest_bootstrap_inbox_id)"
else
    FIRST_INBOX_ID=""
fi

print_step \
    "Step 2/2 — Relaunch check" \
    "On your iPhone:\n1. Open app switcher and force-close Convos.\n2. Reopen Convos from the home screen.\n3. Keep it in the foreground for ~10 seconds."

second_before_count="$(bootstrap_count)"
if wait_for_new_bootstrap "$second_before_count" 120; then
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
