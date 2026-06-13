#!/usr/bin/env bash
# Provision the verified, template-backed debug agents that the Agents-as-Contacts
# QA sequence (qa/tests/structured/36,37,37b) joins against the LOCAL stack.
#
# Each agent runs `convos agent serve` on an isolated CONVOS_HOME with a debug
# attestation, then has its templateId + emoji pushed through the serve FIFO after
# startup (the serve loop's startup ProfileUpdate carries no metadata and would
# otherwise overwrite a join-time templateId). The agent's `ready` event yields an
# invite URL the iOS app opens to join.
#
# Prereqs (see qa/tests/36-agents-as-contacts.md):
#   - The local stack is up:            make -C dev/local-stack status
#   - This checkout points at it:       make -C dev/local-stack ios-config IOS="$(pwd)"
#   - convos CLI on PATH, jq installed.
#
# Usage:
#   qa/scripts/provision-agents-as-contacts.sh start   # mint keypair, pin JWKS, start agents, print invites
#   qa/scripts/provision-agents-as-contacts.sh invites # reprint captured invite URLs
#   qa/scripts/provision-agents-as-contacts.sh fifo <slug> <json>   # push a raw command to an agent
#   qa/scripts/provision-agents-as-contacts.sh rename-fitness        # push the name-only update for test 37
#   qa/scripts/provision-agents-as-contacts.sh stop    # stop agents, remove FIFOs + isolated homes
#
# After `start`, rebuild + relaunch the app so Secrets bakes the pinned JWKS:
#   /run local           (or the xcodebuild + simctl install/launch in the runbook)
# Then open each invite URL on the simulator with: xcrun simctl openurl <UDID> "<invite>"

set -euo pipefail

KEY_PATH="$HOME/.convos-debug-attest.pem"
KID="convos-agents-test"
STATE="/tmp/convos-qa-agents.env"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# persona | emoji | templateId (- = none) | slug
AGENTS=(
  "Fitness Trainer|🏋️|debug-fitness-trainer|fitness-trainer"
  "Trip Planner|🧭|qa-shared-template|trip-planner"
  "Road Tripper|🚗|qa-shared-template|road-tripper"
  "Mystery Bot|🕵️|-|mystery-bot"
)

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m ok \033[0m %s\n' "$*"; }
die() { printf '\033[31mfail\033[0m %s\n' "$*" >&2; exit 1; }

ensure_keypair_and_jwks() {
  command -v convos >/dev/null || die "convos CLI not on PATH"
  command -v jq >/dev/null || die "jq not installed"
  if [[ ! -f "$KEY_PATH" ]]; then
    log "minting debug Ed25519 keypair -> $KEY_PATH"
    convos attestation generate "bootstrap" --kid "$KID" --json > "$HOME/.convos-debug-attest.json"
    jq -r '.privateKeyPem' "$HOME/.convos-debug-attest.json" > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    rm -f "$HOME/.convos-debug-attest.json"
  fi
  local jwks; jwks=$(convos attestation generate "bootstrap" --kid "$KID" --private-key "$(cat "$KEY_PATH")" --json | jq -c '.jwks')
  local env_file="$REPO_ROOT/.env"
  [[ -f "$env_file" ]] || die "no $env_file - run: make -C dev/local-stack ios-config IOS=\"$REPO_ROOT\" first"
  if grep -q '^AGENT_DEBUG_JWKS=' "$env_file"; then
    /usr/bin/sed -i '' "s|^AGENT_DEBUG_JWKS=.*|AGENT_DEBUG_JWKS='${jwks}'|" "$env_file"
  else
    printf "AGENT_DEBUG_JWKS='%s'\n" "$jwks" >> "$env_file"
  fi
  ok "pinned AGENT_DEBUG_JWKS in $env_file (rebuild the app so Secrets bakes it)"
}

start_agent() {
  local persona="$1" emoji="$2" template="$3" slug="$4"
  local home="$HOME/.convos-debug-agent-$slug"
  local fifo="/tmp/convos-qa-agent-$slug.fifo"
  local logf="/tmp/convos-qa-agent-$slug.log"

  CONVOS_HOME="$home" convos init --env dev --force >/dev/null 2>&1 || true
  rm -f "$fifo"; mkfifo "$fifo"
  # Hold the FIFO write-end open so serve never sees EOF; detach so it survives this script.
  nohup bash -c "exec 9>'$fifo'; while true; do sleep 3600; done" >/dev/null 2>&1 &
  disown || true
  # Start the serve loop reading from the FIFO; detach.
  nohup bash -c "CONVOS_HOME='$home' convos agent serve --name '$persona' --profile-name '$persona' \
      --attestation-private-key '$KEY_PATH' --attestation-kid '$KID' --json < '$fifo' > '$logf' 2>&1" >/dev/null 2>&1 &
  disown || true

  log "starting $persona (templateId=$template) ..."
  local invite="" i
  for i in $(seq 1 60); do
    if grep -q '"event":"ready"' "$logf" 2>/dev/null; then break; fi
    sleep 1
  done
  invite=$(grep '"event":"ready"' "$logf" 2>/dev/null | head -1 | jq -r '.inviteUrl // empty')
  [[ -n "$invite" ]] || die "$persona did not emit a ready/inviteUrl (see $logf)"

  # Push templateId + emoji (skipped for the no-template Mystery Bot, which only gets an emoji).
  if [[ "$template" == "-" ]]; then
    printf '{"type":"update-profile","name":"%s","metadata":{"emoji":"%s"}}\n' "$persona" "$emoji" > "$fifo"
  else
    printf '{"type":"update-profile","name":"%s","metadata":{"emoji":"%s","templateId":"%s"}}\n' "$persona" "$emoji" "$template" > "$fifo"
  fi
  ok "$persona ready -> $invite"
  # Emit a state line: INVITE_<slug>=<url>
  printf 'INVITE_%s=%s\n' "$(echo "$slug" | tr 'a-z-' 'A-Z_')" "$invite" >> "$STATE"
}

cmd_start() {
  ensure_keypair_and_jwks
  : > "$STATE"
  for spec in "${AGENTS[@]}"; do
    IFS='|' read -r persona emoji template slug <<< "$spec"
    start_agent "$persona" "$emoji" "$template" "$slug"
  done
  echo
  ok "invite URLs written to $STATE:"
  cat "$STATE"
  echo
  log "next: rebuild + relaunch the Local app (/run local), then open each invite with simctl openurl"
}

cmd_invites() { [[ -f "$STATE" ]] && cat "$STATE" || die "no $STATE - run 'start' first"; }

cmd_fifo() {
  local slug="$1" json="$2" fifo="/tmp/convos-qa-agent-$slug.fifo"
  [[ -p "$fifo" ]] || die "no fifo for $slug ($fifo)"
  printf '%s\n' "$json" > "$fifo"
  ok "pushed to $slug: $json"
}

cmd_rename_fitness() {
  # test 37 name_only_update_keeps_template: metadata-less name change
  cmd_fifo "fitness-trainer" '{"type":"update-profile","name":"Fit Coach"}'
}

cmd_stop() {
  pkill -f "convos agent serve" 2>/dev/null || true
  for spec in "${AGENTS[@]}"; do
    IFS='|' read -r _ _ _ slug <<< "$spec"
    rm -f "/tmp/convos-qa-agent-$slug.fifo" "/tmp/convos-qa-agent-$slug.log"
    rm -rf "$HOME/.convos-debug-agent-$slug"
  done
  rm -f "$STATE"
  ok "stopped agents; removed FIFOs, logs, and isolated homes"
}

case "${1:-}" in
  start)           cmd_start ;;
  invites)         cmd_invites ;;
  fifo)            cmd_fifo "${2:?slug}" "${3:?json}" ;;
  rename-fitness)  cmd_rename_fitness ;;
  stop)            cmd_stop ;;
  *) die "usage: $0 <start|invites|fifo <slug> <json>|rename-fitness|stop>" ;;
esac
