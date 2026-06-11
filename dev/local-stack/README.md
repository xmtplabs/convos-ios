# Convos local stack (for convos-ios devs)

Run the **whole Convos backend + agents stack on your machine** and point the iOS **"Convos (Local)"** scheme at it — so the app's auth, messaging, and the agent-builder ("Make an agent") all run locally.

These scripts are **committed in convos-ios** and operate on an **external workspace** you choose (which holds the cloned service repos + runtime state). **One shared stack** serves every convos-ios checkout/worktree.

```
convos-ios/ (this repo — every checkout/worktree has these scripts)
  dev/local-stack/   Makefile  stack.sh  stack.compose.yml  stack.env.example  README.md
  .convos-stack      → points at your workspace (gitignored, machine-local)

<workspace>/ (you pick this; default: sibling of convos-ios, e.g. ~/Code/xmtplabs/convos-stack —
              or the parent dir itself when the service repos are already cloned next to convos-ios)
  convos-backend/  herald-lite/  convos-assistants/  convos-cli/   ← cloned by `make init`
  stack.env   .run/                                                ← machine-local, shared by all worktrees
```

Services (all on `localhost`, shared): backend `:4000` + Postgres `:5432`, assistants worker `:8787` + Hermes containers + MinIO `:9000`, herald `:5050`. **XMTP = hosted DEV network** (no local node — local users and agents interoperate there).

## Quick start
```bash
cd <a convos-ios checkout>

make -C dev/local-stack doctor       # check prereqs (node, pnpm, bun, docker, op, ...) + Docker CPU cap
make -C dev/local-stack init         # pick a workspace dir + clone the 4 service repos into it
# -> stack.env is written with the team's op://Convos/... refs; sign in to the 1Password CLI
#    ('op signin', account xmtpinc, or 1Password Settings > Developer > CLI integration)
make -C dev/local-stack bootstrap    # deps, generated backend secrets, .dev.vars (1Password), migrations
make -C dev/local-stack up           # start the FULL stack (first run builds the Hermes image; capped)
```
Then run the app:
```
/run local        # Claude command: stack up (if needed) + configure this checkout + build/launch Local
```
or `make -C dev/local-stack ios-config IOS=$(pwd)` then build the **Convos (Local)** scheme.

## Prerequisites
- macOS + **Xcode**, **Docker Desktop** (cap CPUs to ~6 in Settings → Resources — important so the Hermes build can't pin your machine; `make … doctor` warns), **Node 24+**, **pnpm**, **bun**, **1Password CLI** (`op`). `doctor` installs/flags `flock` + `uv`.

## Everyday commands (run from any convos-ios checkout)
| Command | What |
|---|---|
| `make -C dev/local-stack up` | start full stack (most devs) — `up-core` for backend+pg only |
| `make -C dev/local-stack status` | health of every service + Docker cap + load |
| `make -C dev/local-stack logs SVC=worker` | tail a host service's log |
| `make -C dev/local-stack down` | stop everything (keeps Postgres/MinIO data) |
| `make -C dev/local-stack seed-credits` | grant local-dev credits to any unfunded account (run after first sign-in) |
| `/run local` | (Claude) bring stack up + build/launch Local on the branch sim |
| `/local-stack [up\|down\|status\|logs]` | (Claude) manage the shared stack |

The stack is **shared** — don't start a second one per worktree (ports collide). All checkouts point at the same `localhost`; the workspace state lives outside any checkout.

## Secrets (1Password)
- `bootstrap` pulls the assistants **`.dev.vars`** from the `Assistants Local .dev.vars` 1Password item (`op read`), then forces `R2_PARENT_*` to the local MinIO creds.
- Backend JWT / nonce / notification / `DEV_API_TOKEN` secrets are **generated locally**.
- **Firebase App Check**: one **shared Local debug token** (Firebase project `convos-otr`, app `org.convos.ios-local`) lives in 1Password; `ios-config` bakes it into each Local checkout's `.env`.
- Set the `op://` refs (`OP_DEV_VARS_REF`, `OP_FIREBASE_LOCAL_TOKEN_REF`) in `<workspace>/stack.env` once for the team.

### Agent-builder provisioning (auto)
The in-chat agent-builder ("Make an agent") calls convos-backend directly from its Hermes container. `bootstrap` + `up` provision this automatically: they point the worker's **`CONVOS_API_BASE_URL`** at *this* backend via the host's LAN IP (reachable from both the worker process and the container — `localhost`/`host.docker.internal` each only work from one side), and align the backend's **`AGENT_ASSETS_API_KEY`** with the worker's `CONVOS_API_KEY` (or the builder's calls 401). The one manual step: accounts are created on first iOS sign-in, so **after signing in run `make … seed-credits`** to fund the account (else the builder shows "lost power"). `make … up` also seeds on each run.

### Shared iOS `.env` (Dev vs Local)
The workspace also holds **`<workspace>/convos-ios.env`** — the shared **Dev** env (Firebase Dev App Check token, `GATEWAY_URL`, `AGENT_DEBUG_JWKS`). `make init` creates it; **`/firebase-token`**, **`/setup`**, and **`convos-task`** symlink each Dev checkout's `.env → <workspace>/convos-ios.env` (one token, every worktree shares it). They fall back to the legacy `<parent>/.env` when no workspace is configured.

A **`Convos (Local)`** checkout instead gets a **standalone `.env`** (written by `ios-config` / `/run local`: Firebase *Local* token, and `CONVOS_API_BASE_URL` left **empty**) — `ios-config` `rm`s any Dev symlink first so it won't clobber the shared file. The backend URL is intentionally left empty: the build phase bakes `.env` into `Secrets.swift` for **both** schemes and a non-empty value overrides the per-scheme config default, so a hard-coded `localhost` would silently redirect a **Dev** build on the same checkout to localhost (fine on the simulator, "connection refused" on a device). Empty means the **Local** build auto-detects this Mac's LAN IP (reachable from sim and device) while a **Dev** build falls back to `config.dev.json`'s real backend. The Firebase debug token still differs per scheme, so a checkout is still effectively Dev *or* Local at a time on the simulator (a device uses real App Attest, not the debug token).

## Troubleshooting
| Symptom | Fix |
|---|---|
| Machine grinds during first `up` | Docker not CPU-capped → Docker Desktop → Resources → CPUs ≈ 6 (`doctor` warns). |
| iOS app crashes at launch (`…container URL for group identifier`) | Local built without ad-hoc signing → use `/run local` (it passes the flags). |
| iOS auth never completes; Firebase **403 "App attestation failed"** | Shared Local debug token missing → re-run `ios-config`; confirm `.env` has `FIREBASE_APP_CHECK_DEBUG_TOKEN`. |
| Backend `500` on `/auth/*` after Docker restarted | `make … up` re-brings Postgres + re-disables App Check. |
| `herald` won't start: `spawn flock ENOENT` | `brew install flock`. |
| `bootstrap` warns it can't read secrets (`op` not found / not signed in) | `brew install 1password-cli`, then `op signin` — re-run `bootstrap`. |
| Agent stays "Joining…" | worker/herald down or auth incomplete → `make … status`, ensure auth works. |
| Agent-builder: **"Asserted ownerAccountId does not exist"** | worker's `CONVOS_API_BASE_URL` points at the wrong backend (default is the hosted dev one, or the host IP drifted) → `make … up` re-syncs it to this backend; `make … doctor` flags drift. |
| Agent-builder: **"lost power" / Upgrade** | the account has no local credits → after signing in, `make … seed-credits`. |
| **Dev** build hits `localhost` / "connection refused" on a device | the checkout's `.env` has a leftover `CONVOS_API_BASE_URL=localhost` from an old Local config → re-run `make … ios-config` (now writes it empty), or clear that line. Newer `ios-config` no longer hard-codes it. |

## Fixes to upstream (so this needs no workarounds)
- ✅ **convos-ios** `Scripts/build-phases/copy-env-config-main-app.sh:106` `sed` bug (double-escaped backslashes that broke Local `Secrets.swift`) — **fixed in this branch** (committed in-repo; `ios-config` no longer needs to patch it).
- **convos-assistants** `docker-compose.yaml` — MinIO `network_mode: host` doesn't publish ports on macOS; use port mapping (this stack does).
- **convos-assistants** — default `R2_PARENT_*` to local MinIO creds when `IS_LOCAL_DEV=true`.
- **herald-lite** — detect/degrade when `flock` is missing on macOS.
- **convos-ios** (biggest win) — let the **Local** scheme skip Firebase App Check so local dev needs no Firebase token at all.
