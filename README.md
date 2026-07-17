# Convos iOS

[![ConvosCore Tests](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml/badge.svg)](https://github.com/xmtplabs/convos-ios/actions/workflows/convoscore-tests.yml)
[![SwiftLint](https://github.com/xmtplabs/convos-ios/actions/workflows/swiftlint.yml/badge.svg)](https://github.com/xmtplabs/convos-ios/actions/workflows/swiftlint.yml)

Convos is an everyday private chat app for the surveillance age. Built on the open-source, censorship-resistant, post-quantum secure [XMTP protocol](https://xmtp.org), Convos provides instant, impermanent, and self-evidently private conversations.

## What is Convos?

Convos is a privacy-first messenger that offers:
- **No signup** — Simply scan, tap or airdrop into a conversation
- **No numbers** — New identity in every conversation
- **No history** — Time bomb your groupchats with irreversible countdowns
- **No spam** — Every conversation is invitation-only
- **No tracking** — Zero data collection, not even contact info
- **No server** — Messages stored on your device, secured by XMTP

Learn more at [convos.org](https://convos.org).

## Getting started

### Prerequisites

- **macOS** with **Xcode 16+** (the app targets iOS 26)
- **[Homebrew](https://brew.sh)**
- **Docker Desktop** — needed for the ConvosCore test suite (local XMTP node) and to run the local backend/agents stack
- **[1Password CLI](https://developer.1password.com/docs/cli/) (`op`)** — for team secrets (code-signing match password, local-stack secrets)
- Access to the team **1Password** vault and the Firebase project `convos-otr`

### First-time setup

```bash
git clone https://github.com/xmtplabs/convos-ios.git
cd convos-ios
./Scripts/setup.sh        # or: make setup
```

`Scripts/setup.sh` is idempotent and:

- Configures Git hooks (`core.hooksPath` → `Scripts/hooks/`) so SwiftFormat + SwiftLint run on commit/push — works in clones **and** `git worktree`s
- Applies Xcode defaults (trim whitespace, 120-col guide, build durations, …)
- Installs tooling via Homebrew: **SwiftLint** (pinned), **SwiftFormat**, **swift-protobuf**, **GitHub CLI**, **tmux**, **fastlane**
- Adds **`convos-task`** to your shell `PATH` (alias **`ct`**) for the parallel-worktree workflow
- Sets up a **shared Firebase App Check debug token** and symlinks this checkout's `.env` to it (one token across all your worktrees — see `/firebase-token`)
- Runs **`fastlane bootstrap`** to install the team's code-signing certificates/profiles. It prompts for `MATCH_PASSWORD` — grab it from the team 1Password vault. `export MATCH_PASSWORD=…` in your shell rc to skip the prompt next time.

When it finishes, open a new terminal (or `source` your shell rc) so `convos-task` / `ct` are on `PATH`.

> Signing assets live in the encrypted [convos-certificates](https://github.com/xmtplabs/convos-certificates) fastlane *match* repo. If `fastlane bootstrap` is skipped, re-run it later once Xcode is signed in.

### Build & run

The app has three build environments — pick the matching **scheme** in Xcode (or use the commands below). Endpoints, bundle IDs, and secrets handling are documented in **[ENVIRONMENTS.md](ENVIRONMENTS.md)**:

| Scheme | Bundle id | Talks to |
|--------|-----------|----------|
| **Convos (Dev)** | `org.convos.ios-preview` | the hosted **Dev** backend + xmtp (default for day-to-day work) |
| **Convos (Local)** | `org.convos.ios-local` | a **local** backend + agents stack on your machine (see below) |
| **Convos (Prod)** | `org.convos.ios` | production |

**In Xcode:** select a scheme and Run on an iOS 26 simulator.

**With Claude Code** (recommended — handles the simulator-per-branch workflow):

| Command | What it does |
|---------|--------------|
| `/setup` | Create/clone this branch's dedicated simulator, install deps, set build defaults |
| `/run` | Build + launch **Convos (Dev)** on the branch simulator |
| `/run local` | Bring up the local stack (if needed) + build + launch **Convos (Local)** against it |
| `/build`, `/build --run` | Compile (and optionally launch) |
| `/firebase-token` | Capture + pin a Firebase App Check debug token (shared across worktrees) |
| `/test`, `/lint`, `/format` | Run tests / lint / format |

### Running against a local backend + agents (local stack)

The **"Convos (Local)"** scheme can run against the full Convos backend + agents stack on your machine — backend, Postgres, herald, the assistants worker + Hermes containers, and MinIO — over the hosted DEV xmtp network. Auth, messaging, and "Make an agent" all run locally. One **shared** stack serves every checkout/worktree (it lives in a workspace dir you choose; these committed scripts just point at it).

```bash
# one-time per machine (cap Docker Desktop to ~6 CPUs first — Settings → Resources)
make -C dev/local-stack doctor      # check prereqs + Docker CPU cap
make -C dev/local-stack init        # pick a workspace dir + clone the service repos into it
make -C dev/local-stack bootstrap   # deps, secrets (1Password), migrations

# everyday
make -C dev/local-stack up          # start the full stack (first run builds the Hermes image)
make -C dev/local-stack status      # health of every service
make -C dev/local-stack down        # stop it (keeps data)
```

Then build + launch Local with the Claude command **`/run local`** (or `make -C dev/local-stack ios-config IOS=$(pwd)`, then build the Local scheme). Manage the stack from any checkout with **`/local-stack`**.

> Distinct from `./dev/up` (below), which starts a local **xmtp node** for the ConvosCore **test suite** — not the backend/agents stack.

Full runbook (architecture, secrets/1Password, troubleshooting, Dev-vs-Local `.env` rules): **[dev/local-stack/README.md](dev/local-stack/README.md)**.

### Parallel work (git worktrees)

`convos-task` (alias `ct`) spins up isolated worktrees so you can work on several features at once — each gets its own Graphite branch, a dedicated simulator, and an independent Claude Code session, all sharing one Firebase token and the one local stack:

```bash
ct new my-feature       # new worktree + branch + simulator + Claude session
ct list                 # show active tasks
ct cleanup my-feature   # remove when done
```

### Useful make targets

```bash
make setup           # Run Scripts/setup.sh
make status          # Show version, secrets, git, and .env status
make secrets-local   # Regenerate Convos/Config/Secrets.swift for Local builds
make protobuf        # Regenerate Swift code from .proto files
make clean           # Remove generated secrets and build artifacts
```

## Project structure

```
convos-ios/
├── Convos/              # Main iOS application (SwiftUI views + view models)
├── ConvosCore/          # Shared business logic Swift Package (XMTP, GRDB, auth, messaging)
├── ConvosAppData/       # Shared protobuf types + serialization
├── ConvosInvites/       # Invite system (tokens, join requests)
├── NotificationService/ # Push notification extension
├── dev/local-stack/     # One-command local backend + agents stack (see its README)
├── Scripts/             # Setup, build phases, hooks, secrets generation
└── .claude/             # Claude Code commands (/run, /build, /setup, /local-stack, …) + convos-task
```

`ConvosCore` holds all shared business logic — XMTP client management and messaging, GRDB database, authentication/identity, conversation and message handling, and push-notification support. It is built to compile on macOS for fast test execution (no UIKit). See the source files and `CLAUDE.md` for conventions.

## Testing

Most ConvosCore tests require Docker to run a local XMTP node.

```bash
# Full suite — starts Docker, runs tests, stops Docker
./dev/test

# Or manage Docker manually:
./dev/up                                # start local XMTP node
swift test --package-path ConvosCore    # run ConvosCore tests
./dev/down                              # stop when finished

# iOS app tests via xcodebuild
xcodebuild test \
  -project Convos.xcodeproj \
  -scheme "Convos (Local)" \
  -destination "platform=iOS Simulator,name=iPhone 17"
```

## Code quality

Pre-commit and pre-push hooks (installed by `Scripts/setup.sh`) run **SwiftFormat** and **SwiftLint** automatically; violations block the commit/push. Run them manually with `/lint` and `/format`, or `swiftlint` / `swiftformat .`.

See `CLAUDE.md` for architecture conventions, SwiftUI/type-checker rules, and the Graphite-based PR workflow.
