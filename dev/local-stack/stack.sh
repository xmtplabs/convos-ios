#!/usr/bin/env bash
# convos local stack — committed in convos-ios, operates on an EXTERNAL workspace dir
# (CONVOS_REPOS_DIR) that holds the cloned service repos + machine-local state. One shared
# stack serves every convos-ios checkout/worktree. See README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # convos-ios/dev/local-stack
COMPOSE_FILE="${SCRIPT_DIR}/stack.compose.yml"
COMPOSE_PROJECT="convos-stack"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
POINTER="${REPO_ROOT}/.convos-stack"                              # gitignored: points at the workspace

SERVICE_REPOS=(convos-backend herald-lite convos-assistants convos-cli)
GH_BASE="${GH_BASE:-https://github.com/xmtplabs}"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s warn%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

resolve_workspace() {
  if   [[ -n "${CONVOS_REPOS_DIR:-}" ]]; then WORKSPACE="$CONVOS_REPOS_DIR"
  elif [[ -f "$POINTER" ]];            then WORKSPACE="$(tr -d '\n' < "$POINTER")"
  else WORKSPACE=""; fi
}

load_env() {
  resolve_workspace
  [[ -n "$WORKSPACE" ]] || die "no workspace configured — run: make init"
  [[ -f "${WORKSPACE}/stack.env" ]] || die "no ${WORKSPACE}/stack.env — run: make init"
  set -a; . "${WORKSPACE}/stack.env"; set +a
  CONVOS_REPOS_DIR="$WORKSPACE"
  BACKEND_DIR="${BACKEND_DIR:-${WORKSPACE}/convos-backend}"
  HERALD_DIR="${HERALD_DIR:-${WORKSPACE}/herald-lite}"
  ASSISTANTS_DIR="${ASSISTANTS_DIR:-${WORKSPACE}/convos-assistants}"
  CLI_DIR="${CLI_DIR:-${WORKSPACE}/convos-cli}"
  WORKER_DIR="${WORKER_DIR:-${ASSISTANTS_DIR}/workers/assistant}"
  : "${BACKEND_PORT:=4000}" "${HERALD_PORT:=5050}" "${WORKER_PORT:=8787}" "${MINIO_PORT:=9000}"
  : "${XMTP_ENV:=dev}" "${SIWE_DOMAIN:=dev.convos.org}" "${SIWE_URI:=https://dev.convos.org}"
  : "${MINIO_USER:=convos}" "${MINIO_PASSWORD:=assistants}" "${MINIO_BUCKET:=assistants-private-dev}"
  : "${DOCKER_MAX_CPUS:=6}"
  export BACKEND_PORT HERALD_PORT WORKER_PORT MINIO_PORT MINIO_CONSOLE_PORT MINIO_USER MINIO_PASSWORD MINIO_BUCKET PG_PORT
  RUN_DIR="${WORKSPACE}/.run"; mkdir -p "$RUN_DIR"
}

# stack.env is already sourced+exported, so compose reads the vars from the environment.
dc() { docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"; }

wait_http() { local url="$1" t="${2:-60}" i=0; while (( i < t )); do local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"; [[ "$c" =~ ^2[0-9][0-9]$ ]] && return 0; sleep 1; ((i++)); done; return 1; }

start_svc() { local name="$1" dir="$2"; shift 2; if svc_running "$name"; then ok "$name already running"; return 0; fi; [[ -d "$dir" ]] || die "$name dir missing: $dir"; log "starting $name ${c_dim}($dir)${c_rst}"; ( cd "$dir" && nohup bash -lc "$*" >"$RUN_DIR/$name.log" 2>&1 & echo $! >"$RUN_DIR/$name.pid" ); }
svc_running() { local n="$1"; [[ -f "$RUN_DIR/$n.pid" ]] && kill -0 "$(cat "$RUN_DIR/$n.pid")" 2>/dev/null; }
stop_svc() { local name="$1" pat="${2:-}"; [[ -f "$RUN_DIR/$name.pid" ]] && kill "$(cat "$RUN_DIR/$name.pid")" 2>/dev/null || true; [[ -n "$pat" ]] && pkill -f "$pat" 2>/dev/null || true; rm -f "$RUN_DIR/$name.pid"; }
disable_app_check() { local tok; tok="$(grep -E '^DEV_API_TOKEN=' "${BACKEND_DIR}/.env" 2>/dev/null | cut -d= -f2-)"; [[ -z "$tok" ]] && { warn "no DEV_API_TOKEN; can't disable App Check"; return; }; curl -s -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"enabled":false}' "http://localhost:${BACKEND_PORT}/api/v2/dev/app-attest" >/dev/null 2>&1 && ok "App Check disabled" || warn "couldn't disable App Check"; }

# ============================ init (clone wizard) ============================
cmd_init() {
  local default_ws; default_ws="$(dirname "$REPO_ROOT")/convos-stack"   # sibling of the convos-ios checkout
  local ws="${1:-${CONVOS_REPOS_DIR:-}}"
  if [[ -z "$ws" ]]; then
    if [[ -t 0 ]]; then read -r -p "Workspace dir for the local stack [${default_ws}]: " ws || true; fi
    ws="${ws:-$default_ws}"
  fi
  mkdir -p "$ws"; ws="$(cd "$ws" && pwd)"
  printf '%s\n' "$ws" > "$POINTER"; ok "pointer written: ${POINTER} -> ${ws}"

  log "cloning service repos into ${ws} (skips any already present)"
  for r in "${SERVICE_REPOS[@]}"; do
    if [[ -d "${ws}/${r}/.git" ]]; then ok "${r} already cloned"
    else log "git clone ${r}"; git clone "${GH_BASE}/${r}.git" "${ws}/${r}" || warn "clone ${r} failed — clone it manually into ${ws}/${r}"; fi
  done

  if [[ ! -f "${ws}/stack.env" ]]; then
    sed "s|^CONVOS_REPOS_DIR=.*|CONVOS_REPOS_DIR=${ws}|" "${SCRIPT_DIR}/stack.env.example" > "${ws}/stack.env"
    ok "wrote ${ws}/stack.env — set OP_* 1Password refs in it before `make bootstrap`"
  else ok "${ws}/stack.env exists (left as-is)"; fi
  if [[ ! -f "${ws}/convos-ios.env" ]]; then
    printf '# Shared convos-ios DEV .env (Firebase App Check debug token, GATEWAY_URL, AGENT_DEBUG_JWKS, ...).\n# Dev convos-ios checkouts symlink their .env to this file; run /firebase-token to pin the token.\nFIREBASE_APP_CHECK_DEBUG_TOKEN=\nAGENT_DEBUG_JWKS=\nGATEWAY_URL=\nSENTRY_DSN=\n' > "${ws}/convos-ios.env"
    ok "created ${ws}/convos-ios.env (shared Dev env — convos-ios checkouts symlink their .env here)"
  fi
  ok "init done. Next: edit ${ws}/stack.env (OP_* refs), then: make bootstrap && make up"
}

# ============================ doctor ============================
cmd_doctor() {
  resolve_workspace
  [[ -n "$WORKSPACE" ]] && ok "workspace: ${WORKSPACE}" || warn "no workspace yet (run: make init)"
  log "prerequisites"
  for t in node pnpm bun docker openssl curl git; do have "$t" && ok "$t $($t --version 2>/dev/null | head -1)" || warn "$t MISSING"; done
  have uv && ok "uv $(uv --version)" || warn "uv MISSING (brew install uv) — assistants repo-setup"
  have flock && ok "flock present" || warn "flock MISSING (brew install flock) — herald on macOS"
  have op && ok "1Password CLI present" || warn "op MISSING (brew install 1password-cli) — secrets"
  have xcodebuild && ok "Xcode $(xcodebuild -version 2>/dev/null | head -1)" || warn "xcodebuild MISSING"
  if docker info >/dev/null 2>&1; then
    local ncpu; ncpu="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo '?')"
    if [[ "$ncpu" =~ ^[0-9]+$ ]] && (( ncpu > ${DOCKER_MAX_CPUS:-6} )); then
      warn "Docker has ${ncpu} CPUs — cap to ${DOCKER_MAX_CPUS:-6} (Docker Desktop > Settings > Resources) so the Hermes build can't starve the host"
    else ok "Docker running, ${ncpu} CPUs"; fi
  else die "Docker not running"; fi
}

# ============================ bootstrap ============================
cmd_bootstrap() {
  load_env
  cmd_doctor || true
  have flock || brew install flock || warn "brew install flock failed"
  have uv    || brew install uv    || warn "brew install uv failed"
  bootstrap_backend; bootstrap_herald; bootstrap_assistants; bootstrap_cli
  ok "bootstrap complete — now: make up   (then in a convos-ios checkout: /run local)"
}
bootstrap_backend() {
  log "convos-backend: env + deps + codegen + migrations"; pushd "$BACKEND_DIR" >/dev/null
  pnpm install
  if [[ ! -f .env ]]; then
    local keys; keys="$(pnpm tsx dev/scripts/generateEcdsaKeys.ts 2>/dev/null)"
    grep -vE '^(JWT_PRIVATE_KEY|JWT_PUBLIC_KEY|XMTP_NOTIFICATION_SECRET|NONCE_HMAC_SECRET|SIWE_DOMAIN|SIWE_URI|WEBSITE_URL|DEV_API_TOKEN|XMTP_ENV)=' .env.example > .env
    { printf '\n# --- convos local stack ---\n'
      printf '%s\n' "$keys" | grep '^JWT_PRIVATE_KEY='; printf '%s\n' "$keys" | grep '^JWT_PUBLIC_KEY='
      printf 'XMTP_NOTIFICATION_SECRET=%s\n' "$(openssl rand -hex 32)"
      printf 'NONCE_HMAC_SECRET=%s\n' "$(openssl rand -hex 32)"
      printf 'WEBSITE_URL=%s\nSIWE_DOMAIN=%s\nSIWE_URI=%s\n' "$SIWE_URI" "$SIWE_DOMAIN" "$SIWE_URI"
      printf 'DEV_API_TOKEN=%s\nXMTP_ENV=%s\n' "$(openssl rand -hex 24)" "$XMTP_ENV"
    } >> .env; ok "wrote convos-backend/.env"
  else ok "convos-backend/.env exists"; fi
  pnpm prisma:generate >/dev/null && pnpm buf:generate >/dev/null && ok "codegen done"
  dc up -d convos_db --wait >/dev/null 2>&1 || dc up -d convos_db
  pnpm migrate:deploy >/dev/null && ok "migrations applied"; popd >/dev/null
}
bootstrap_herald() {
  log "herald-lite: env + deps"; pushd "$HERALD_DIR" >/dev/null; pnpm install
  [[ -f .env ]] || printf 'DATA_DIR=./data\nPORT=%s\nENV=dev\nXMTP_ENV=%s\nLOG_LEVEL=info\n' "$HERALD_PORT" "$XMTP_ENV" > .env
  ok "herald-lite/.env ready"; popd >/dev/null
}
bootstrap_assistants() {
  log "convos-assistants: deps + .dev.vars + repo-setup"; pushd "$ASSISTANTS_DIR" >/dev/null; pnpm install
  local dv="${WORKER_DIR}/.dev.vars"
  if [[ ! -f "$dv" ]]; then
    if have op && [[ -n "${OP_DEV_VARS_REF:-}" ]] && op read "$OP_DEV_VARS_REF" >"$dv" 2>/dev/null; then ok "fetched .dev.vars from 1Password"
    else warn "populate ${dv} from 1Password item 'Assistants Local .dev.vars' (op not set up / OP_DEV_VARS_REF unset)"; fi
  fi
  if [[ -f "$dv" ]]; then
    sed -i '' -E "s|^R2_PARENT_ACCESS_KEY_ID=.*|R2_PARENT_ACCESS_KEY_ID=${MINIO_USER}|; s|^R2_PARENT_SECRET_ACCESS_KEY=.*|R2_PARENT_SECRET_ACCESS_KEY=${MINIO_PASSWORD}|" "$dv" 2>/dev/null || true
    grep -q '^R2_PARENT_ACCESS_KEY_ID=' "$dv" || printf 'R2_PARENT_ACCESS_KEY_ID=%s\nR2_PARENT_SECRET_ACCESS_KEY=%s\n' "$MINIO_USER" "$MINIO_PASSWORD" >>"$dv"
    ok ".dev.vars R2_PARENT_* set to local MinIO creds"
  fi
  if have uv; then pnpm run repo-setup >/dev/null 2>&1 && ok "repo-setup done" || warn "repo-setup failed (check uv)"; fi
  popd >/dev/null
}
bootstrap_cli() { log "convos-cli: deps + build"; pushd "$CLI_DIR" >/dev/null; pnpm install && pnpm build >/dev/null 2>&1 && ok "cli built" || warn "cli build failed"; popd >/dev/null; }

# ============================ up / down ============================
cmd_up() {
  load_env; local tier="${1:-full}"; docker info >/dev/null 2>&1 || die "Docker not running"
  log "infra ($([[ $tier == full ]] && echo 'Postgres + MinIO' || echo 'Postgres'))"
  if [[ "$tier" == full ]]; then dc up -d --wait || dc up -d; else dc up -d convos_db --wait || dc up -d convos_db; fi
  start_svc backend "$BACKEND_DIR" "pnpm dev"
  wait_http "http://localhost:${BACKEND_PORT}/healthcheck" 60 && ok "backend up" || warn "backend not healthy (make logs SVC=backend)"
  disable_app_check
  if [[ "$tier" == full ]]; then
    start_svc herald "$HERALD_DIR" "pnpm start"
    wait_http "http://localhost:${HERALD_PORT}/livez" 30 && ok "herald up" || warn "herald not healthy (make logs SVC=herald)"
    start_svc worker "$WORKER_DIR" "pnpm dev"
    log "waiting for worker :${WORKER_PORT} (first run builds Hermes image — minutes, capped)"
    wait_http "http://localhost:${WORKER_PORT}/openapi.json" 1200 && ok "worker up (Hermes ready)" || warn "worker still starting (make logs SVC=worker)"
  fi
  echo; cmd_status
}
cmd_down() {
  load_env; log "stopping host services"
  stop_svc worker  "with-wrangler-docker-fuse-proxy|run-wrangler.sh|workerd|miniflare"
  stop_svc herald  "${HERALD_DIR}.*src/index.ts"
  # herald holds a single-writer flock via a child `flock ... herald.lock` process that
  # survives the node process; kill it too, or the next herald start hangs 600s on the lock.
  pkill -f "herald.lock" 2>/dev/null || true
  pkill -f "sleep 2147483647" 2>/dev/null || true
  stop_svc backend "${BACKEND_DIR}.*src/index.ts"
  log "stopping infra (data kept)"; dc stop >/dev/null 2>&1 || true; ok "stopped"
}

# ============================ status / logs ============================
cmd_status() {
  load_env; log "service health"
  chk() { local n="$1" u="$2" c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" 2>/dev/null || echo 000)"; [[ "$c" =~ ^2[0-9][0-9]$ ]] && ok "$(printf '%-8s %s' "$n" "$u") -> $c" || warn "$(printf '%-8s %s' "$n" "$u") -> ${c/000/down}"; }
  chk backend "http://localhost:${BACKEND_PORT}/healthcheck"
  chk herald  "http://localhost:${HERALD_PORT}/livez"
  chk worker  "http://localhost:${WORKER_PORT}/openapi.json"
  chk minio   "http://localhost:${MINIO_PORT}/minio/health/live"
  docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null | grep -iE "convos-stack" || true
  printf '  %sworkspace=%s · docker CPUs=%s · load=%s%s\n' "$c_dim" "$WORKSPACE" "$(docker info --format '{{.NCPU}}' 2>/dev/null||echo '?')" "$(uptime|sed -E 's/.*load average[s]*: *([0-9.]+).*/\1/')" "$c_rst"
}
cmd_logs() { load_env; local svc="${1:-}"; if [[ -n "$svc" ]]; then tail -f "$RUN_DIR/${svc}.log"; else [[ -n "$(ls "$RUN_DIR"/*.log 2>/dev/null||true)" ]] || die "no logs yet (make up)"; tail -f "$RUN_DIR"/*.log; fi; }

cmd_hermes_build() { load_env; docker info >/dev/null 2>&1 || die "Docker not running"; log "building Hermes image (capped)"; pushd "$WORKER_DIR" >/dev/null; pnpm exec wrangler containers build ./../../runtime/hermes/Dockerfile || pnpm run prebuild; popd >/dev/null; ok "Hermes image cached"; }

# ============================ ios-config ============================
cmd_ios_config() {
  load_env; local ios="${1:-$REPO_ROOT}"
  [[ -f "$ios/Convos/Config/config.local.json" ]] || die "not a convos-ios checkout: $ios"
  log "configuring Local thin client: $ios"
  if grep -q '"xmtpNetwork": "dev"' "$ios/Convos/Config/config.local.json"; then ok "config.local.json xmtpNetwork already 'dev'"
  else sed -i '' 's/"xmtpNetwork": "local"/"xmtpNetwork": "dev"/' "$ios/Convos/Config/config.local.json" 2>/dev/null && ok "config.local.json xmtpNetwork -> dev"; fi
  local fb=""; { have op && [[ -n "${OP_FIREBASE_LOCAL_TOKEN_REF:-}" ]] && fb="$(op read "$OP_FIREBASE_LOCAL_TOKEN_REF" 2>/dev/null||true)"; } || true
  [[ -z "$fb" ]] && warn "no Firebase Local token from 1Password — set FIREBASE_APP_CHECK_DEBUG_TOKEN in $ios/.env (shared Local token)"
  rm -f "$ios/.env"   # break any Dev-shared symlink; the Local scheme uses a standalone .env
  { printf 'CONVOS_API_BASE_URL=http://localhost:%s/api\nGATEWAY_URL=\nSENTRY_DSN=\nFIREBASE_APP_CHECK_DEBUG_TOKEN=%s\nAGENT_DEBUG_JWKS=\n' "$BACKEND_PORT" "$fb"; } > "$ios/.env"
  ok "wrote standalone Local $ios/.env (localhost backend + Firebase Local token; any Dev symlink replaced)"
}

cmd_clean() { load_env; cmd_down; rm -rf "$RUN_DIR"; ok "cleaned run state"; }
cmd_nuke()  { load_env; cmd_down; rm -rf "$RUN_DIR"; dc down -v >/dev/null 2>&1 || true; warn "dropped docker volumes (Postgres + MinIO data wiped)"; }

case "${1:-}" in
  init)         shift; cmd_init "${1:-}";;
  bootstrap)    cmd_bootstrap;;
  up)           cmd_up "${2:-full}";;
  down)         cmd_down;;
  status)       cmd_status;;
  logs)         cmd_logs "${2:-}";;
  hermes-build) cmd_hermes_build;;
  ios-config)   cmd_ios_config "${2:-}";;
  doctor)       cmd_doctor;;
  clean)        cmd_clean;;
  nuke)         cmd_nuke;;
  *) die "usage: stack.sh <init|bootstrap|up [full|core]|down|status|logs [svc]|hermes-build|ios-config [path]|doctor|clean|nuke>";;
esac
