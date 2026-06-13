---
description: Manage the shared local Convos stack (backend + Postgres + herald + assistants/Hermes + MinIO).
---

# /local-stack

Control the **shared** local backend+agents stack that the "Convos (Local)" scheme runs against. The orchestration is committed here in `dev/local-stack/`; it operates on an external workspace (the dir holding the cloned service repos + runtime state). One stack serves every convos-ios checkout/worktree. (To also build+launch the app, use `/run local`.)

## Usage
```
/local-stack            # status (default)
/local-stack init       # first-time: pick a workspace dir + clone the service repos
/local-stack bootstrap  # one-time per machine: deps, secrets (1Password), migrations
/local-stack up         # start the full stack (backend, pg, herald, worker+Hermes, minio)
/local-stack down       # stop host services + infra (keeps data volumes)
/local-stack logs       # tail logs  (add: backend|herald|worker)
/local-stack doctor     # check prereqs + Docker CPU cap
```

## Instructions

1. **Resolve the make dir** (always in THIS repo): `LS="$(git rev-parse --show-toplevel)/dev/local-stack"`.
2. **Run the target** from there: `make -C "$LS" <target>` (map `logs <svc>` → `make -C "$LS" logs SVC=<svc>`).
   | arg | target | timeout |
   |-----|--------|---------|
   | (none)/`status` | `status` | 30s |
   | `init` | `init` | 600000ms (clones 4 repos) |
   | `bootstrap` | `bootstrap` | 1200000ms |
   | `up` | `up` | **1200000ms** (first run builds the Hermes image) |
   | `down` | `down` | 60s |
   | `logs [svc]` | `logs SVC=<svc>` | stream / background |
   | `doctor` | `doctor` | 60s |
3. **First-run handling:** if a command fails with *"no workspace configured — run: make init"*, the dev hasn't set up the workspace. Run `make -C "$LS" init` — it defaults the workspace to a **sibling of this repo** (`<repo-parent>/convos-stack`) and clones the service repos there. Confirm the path with the user first if you can. Then they edit `<workspace>/stack.env` (the `OP_*` 1Password refs) and run `bootstrap`.
4. **Relay results** concisely; surface any `doctor` warnings — especially the **Docker-CPU-cap** one (it's what keeps the Hermes build from overloading the machine).

## Notes
- First `up` ever builds the Hermes container image — minutes, but capped to Docker's CPU limit. Later `up`s are seconds.
- The stack is **shared** — one instance, many thin iOS checkouts (don't start a second; ports collide). It uses the hosted **DEV** xmtp network.
- One-time per machine: `init` → set `OP_*` refs in `<workspace>/stack.env` → `bootstrap`, and cap Docker Desktop CPUs per `doctor`.
