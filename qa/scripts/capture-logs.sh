#!/bin/bash
# capture-logs.sh -- multi-layer log capture for QA runs.
#
# Snapshots logs from every layer of the app into the run's artifact
# directory so the HTML run artifact can embed and analyze them:
#
#   app        iOS app-group convos.log (the authoritative app log)
#   backend    local stack convos-backend (host process, <workspace>/.run/backend.log)
#   herald     local stack herald-lite (host process, <workspace>/.run/herald.log)
#   worker     local stack assistants worker (host process, <workspace>/.run/worker.log)
#   postgres   docker container logs (convos-stack project)
#   minio      docker container logs (convos-stack project)
#   agents     QA debug agents (/tmp/convos-qa-agent-*.log)
#
# Usage:
#   capture-logs.sh start <run_id> <udid>   # record byte-offset / time markers at run start
#   capture-logs.sh dump  <run_id> <udid>   # write each layer's log since the markers
#
# Layers degrade gracefully: anything not present (no local stack workspace,
# docker down, no agents running) is skipped with a note. Output lands in
# qa/artifacts/run-<run_id>/logs/. Safe to re-run dump; it overwrites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CMD="${1:?usage: capture-logs.sh <start|dump> <run_id> <udid>}"
RUN_ID="${2:?run_id required}"
UDID="${3:?udid required}"

LOG_DIR="$REPO_ROOT/qa/artifacts/run-$RUN_ID/logs"
MARKERS="$LOG_DIR/.markers"
mkdir -p "$LOG_DIR"

# Helpers are used in $(...) substitutions under set -e -o pipefail; every
# pipeline ends in || true so a missing path degrades to empty, not an exit.

resolve_app_log() {
    find ~/Library/Developer/CoreSimulator/Devices/"$UDID"/data/Containers/Shared/AppGroup \
        -name "convos.log" -type f 2>/dev/null | head -1 || true
}

resolve_workspace() {
    # Worktrees don't carry the gitignored .convos-stack pointer; fall back to
    # the main checkout's copy (the parent of the shared .git dir).
    local main_root
    if [ -n "${CONVOS_REPOS_DIR:-}" ]; then
        echo "$CONVOS_REPOS_DIR"
    elif [ -f "$REPO_ROOT/.convos-stack" ]; then
        tr -d '\n' < "$REPO_ROOT/.convos-stack"
    else
        # Resolve the shared .git dir first and only dirname a non-empty result:
        # dirname "" returns "." which would falsely pass the -n check below.
        main_root="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || true
        if [ -n "$main_root" ]; then
            main_root="$(dirname "$main_root")"
        fi
        if [ -n "$main_root" ] && [ -f "$main_root/.convos-stack" ]; then
            tr -d '\n' < "$main_root/.convos-stack"
        fi
    fi
}

file_size() { { wc -c < "$1" 2>/dev/null || echo 0; } | tr -d ' '; }

# Markers file format: one tab-separated record per line.
#   meta <tab> started_at <tab> <iso-ts>
#   file <tab> <layer>     <tab> <path> <tab> <byte-offset>
mark() { printf 'file\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MARKERS"; }

get_marker_offset() {
    # get_marker_offset <layer> <path> -- empty string if not recorded
    awk -F'\t' -v l="$1" -v p="$2" '$1=="file" && $2==l && $3==p {print $4; exit}' "$MARKERS" 2>/dev/null || true
}

slice_file() {
    # slice_file <layer> <src> <dest> -- write bytes since the recorded marker.
    # If the file shrank (app relaunch truncates convos.log) or has no marker
    # (file appeared mid-run), dump from the beginning.
    local layer="$1" src="$2" dest="$3"
    [ -f "$src" ] || return 1
    local offset size
    offset=$(get_marker_offset "$layer" "$src")
    size=$(file_size "$src")
    if [ -z "$offset" ] || [ "$size" -lt "$offset" ]; then
        offset=0
    fi
    tail -c +$((offset + 1)) "$src" > "$dest"
}

cmd_start() {
    : > "$MARKERS"
    printf 'meta\tstarted_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MARKERS"

    local app_log
    app_log=$(resolve_app_log)
    if [ -n "$app_log" ]; then
        mark app "$app_log" "$(file_size "$app_log")"
        echo "marked app log: $app_log"
    else
        echo "note: no app-group convos.log yet for $UDID (app not launched?)"
    fi

    local ws
    ws=$(resolve_workspace)
    if [ -n "$ws" ] && [ -d "$ws/.run" ]; then
        local svc
        for svc in backend herald worker; do
            if [ -f "$ws/.run/$svc.log" ]; then
                mark "$svc" "$ws/.run/$svc.log" "$(file_size "$ws/.run/$svc.log")"
                echo "marked $svc log"
            fi
        done
    else
        echo "note: no local stack workspace -- backend/herald/worker capture disabled"
    fi

    local agent_log
    for agent_log in /tmp/convos-qa-agent-*.log; do
        [ -f "$agent_log" ] || continue
        mark agent "$agent_log" "$(file_size "$agent_log")"
        echo "marked agent log: $(basename "$agent_log")"
    done

    echo "markers written: $MARKERS"
}

cmd_dump() {
    if [ ! -f "$MARKERS" ]; then
        echo "note: no markers recorded ('start' was never run) -- dumping full logs"
        printf 'meta\tstarted_at\t%s\n' "unknown" > "$MARKERS"
    fi
    local started_at
    started_at=$(awk -F'\t' '$1=="meta" && $2=="started_at" {print $3; exit}' "$MARKERS")

    # App log: the container can change identity mid-run (test 01 erases the
    # simulator, reinstall creates a new app-group UUID), so re-resolve and
    # fall back to a full dump when the path no longer matches the marker.
    local app_log
    app_log=$(resolve_app_log)
    if [ -n "$app_log" ]; then
        slice_file app "$app_log" "$LOG_DIR/app.log" && echo "captured app.log ($(file_size "$LOG_DIR/app.log") bytes)"
    else
        echo "skip: app log not found for $UDID"
    fi

    local ws
    ws=$(resolve_workspace)
    if [ -n "$ws" ] && [ -d "$ws/.run" ]; then
        local svc
        for svc in backend herald worker; do
            if slice_file "$svc" "$ws/.run/$svc.log" "$LOG_DIR/$svc.log" 2>/dev/null; then
                echo "captured $svc.log ($(file_size "$LOG_DIR/$svc.log") bytes)"
            else
                echo "skip: $svc (no log at $ws/.run/$svc.log)"
            fi
        done
    else
        echo "skip: backend/herald/worker (no local stack workspace)"
    fi

    if docker info >/dev/null 2>&1; then
        local name short since_args=()
        [ -n "$started_at" ] && [ "$started_at" != "unknown" ] && since_args=(--since "$started_at")
        for name in $(docker ps -a --filter "name=convos-stack" --format '{{.Names}}' 2>/dev/null); do
            short=$(echo "$name" | sed -E 's/^convos-stack[-_]//; s/[-_][0-9]+$//')
            # ${arr[@]+...} guards the expansion: plain "${since_args[@]}" on an
            # empty array trips set -u under macOS system bash 3.2.
            docker logs ${since_args[@]+"${since_args[@]}"} "$name" > "$LOG_DIR/$short.log" 2>&1 || true
            echo "captured $short.log ($(file_size "$LOG_DIR/$short.log") bytes)"
        done
    else
        echo "skip: docker containers (docker not running)"
    fi

    local agent_log base
    for agent_log in /tmp/convos-qa-agent-*.log; do
        [ -f "$agent_log" ] || continue
        base=$(basename "$agent_log" .log | sed 's/^convos-qa-//')
        slice_file agent "$agent_log" "$LOG_DIR/$base.log" && echo "captured $base.log ($(file_size "$LOG_DIR/$base.log") bytes)"
    done

    echo "logs captured to: $LOG_DIR"
}

case "$CMD" in
    start) cmd_start ;;
    dump)  cmd_dump ;;
    *) echo "usage: capture-logs.sh <start|dump> <run_id> <udid>" >&2; exit 1 ;;
esac
