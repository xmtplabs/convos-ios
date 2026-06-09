---
name: simulator-bringup
description: Use when building, upgrading a dependency (e.g. libxmtp), or installing the Convos iOS app in a local simulator - especially if the app crashes on launch or shows the generic "Something went wrong" sheet when starting a new convo. Encodes the issue #843 bring-up procedure (scheme choice; app-group, Keychain, and App Check accommodations; the local backend on :4000) plus the build-contention type-check workaround learned in practice.
---

# Convos iOS simulator bring-up

A clean simulator bring-up needs a few simulator-specific accommodations. Without
them, `Convos (Local)` crashes on launch and `Convos (Dev)` reaches the UI but
shows the generic `Something went wrong` sheet when starting a new convo. This
skill is the procedure for getting a build running in a local simulator and
verifying it, e.g. after a dependency upgrade or a fresh install.

Source of record: GitHub issue
[#843](https://github.com/xmtplabs/convos-ios/issues/843).

## When to run this

- After upgrading a dependency (libxmtp bump, package re-resolve) and you want to
  confirm the app still builds and launches.
- On a fresh checkout / first simulator install.
- Any time a simulator build crashes on launch or shows `Something went wrong`.

For the plain build-and-launch mechanics, `/run` (or `/build --run`) already does
the heavy lifting. This skill adds the bring-up gotchas and the contention
workaround on top.

## Step 0 - pick the scheme

| Scheme | API base | Local backend required? | Bundle id |
|--------|----------|-------------------------|-----------|
| `Convos (Dev)` (recommended) | `https://api.dev.convos.xyz/api` | No | `org.convos.ios-preview` |
| `Convos (Local)` | `http://<host>:4000/api` | Yes - API on `:4000` | `org.convos.ios-local` |

Default to `Convos (Dev)` unless you specifically need local backend data.
`dev/docker-compose.yml` / the local stack start XMTP infra but a Convos backend
API on `:4000` must also be running for `Convos (Local)`; otherwise new-convo
shows the error sheet. Use `/run local` (see `.claude/commands/run.md`) to bring
up the shared local stack before a `Convos (Local)` run.

## Step 1 - build and launch

1. Resolve the dedicated simulator (`.claude/.simulator_id`, else `.convos-task`
   `SIMULATOR_NAME`, else derive `convos-<branch>`; `main` -> `convos-main`). On
   a generic machine this is typically the booted `convos-dev` simulator.
2. After a dependency bump, re-resolve first so the new revision is fetched:
   ```bash
   xcodebuild -resolvePackageDependencies -project Convos.xcodeproj \
     -scheme "Convos (Dev)" -derivedDataPath .derivedData
   ```
3. Build, install, and launch (XcodeBuildMCP `build_run_sim`, or `/run`). Keep
   builds isolated to this worktree with `-derivedDataPath .derivedData`, and
   **set `configuration: Dev`** (session defaults or `-configuration Dev`) - see
   the NotificationService note below.
4. Confirm it actually came up with a screenshot - do not trust "launched"
   alone. Expected: the Chats home screen, no error modal.

### First build fails: NotificationService module resolution

Symptom on the first `Convos (Dev)` simulator build:
```
unable to resolve module dependency: 'ConvosCore' / 'ConvosCoreiOS' / 'XMTPiOS'
```
in the NotificationService extension, even though ConvosCore itself compiled
fine. This is a build-configuration mismatch, not stale DerivedData. With no
configuration set, SPM packages land in `Debug-iphonesimulator/` while the
extension looks in `Release-iphonesimulator/PackageFrameworks/` (empty). `rm -rf
.derivedData` does **not** fix it.

Fix: set `configuration: Dev` so everything lands in `Dev-iphonesimulator/`.
Setting it up front (step 3) avoids the wasted first build entirely.

### Build under machine load (type-check contention)

The project compiles with `-warn-long-expression-type-checking 100` /
`-warn-long-function-bodies 100` and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, so a
slow type-check is a hard build failure. Two very different causes:

- **Genuinely slow expression** - the error names one specific non-trivial
  expression and reproduces on the same line every build. Fix the code (hoist
  typed `let`s, split the body). Never raise the threshold. See CLAUDE.md
  "Build Performance: Type-Check Time".
- **CPU contention** - the timeout is a *trivial* expression (a two-property
  bool, a `guard let`), the reported time hovers just over the limit
  (~305-370ms), and which file trips it *changes between builds*. This is the
  machine being starved (e.g. OrbStack/Docker, browser), not the code.

Confirm it is contention before touching anything: `sysctl -n vm.loadavg` and
`ps -Ao %cpu,comm -r | head` against `sysctl -n hw.ncpu`. A load average near or
above the core count, with heavy non-build processes on top, is the tell - then
treat it as contention, not slow code.

For contention only:

1. Reduce competing load if you can (close heavy apps). Do not pause a user's
   running stack (OrbStack/Docker) without asking - it may be in active use.
2. Lower build parallelism: pass `-jobs 2` (or `-jobs 1`) to reduce the build's
   own internal contention.
3. If load cannot be freed and you just need a runnable local build, override
   warnings-as-errors **on the command line only** for that one run:
   ```
   extraArgs: ["-jobs", "2", "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO"]
   ```
   This keeps the contention-induced timeouts as warnings so the build can link
   and launch. It does **not** raise the threshold and must **never** be
   committed or used to paper over a genuinely slow expression - only for
   provably environmental timeouts on trivial code.

## Step 2 - launch crash: app group container fallback

Symptom on launch:
```
EXC_BREAKPOINT / _assertionFailure
AppEnvironment.defaultXMTPLogsDirectoryURL.getter   (AppEnvironment.swift)
fatalError("Failed getting container URL for group identifier...")
```
The XMTP logs / databases dirs come from the app group container via
`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`, which
can be unavailable in the simulator.

Accommodation: use the app group container when available, else fall back to
`Application Support/<bundle id>/` (`AppEnvironment.swift`,
`defaultXMTPLogsDirectoryURL` / `defaultDatabasesDirectoryURL`).

## Step 3 - new-convo fails: file-backed identity store on simulator

Symptom:
```
Keychain identity read failed (keychainOperationFailed(-34018, "load"))
```
`-34018` (`errSecMissingEntitlement`) is the simulator Keychain access-group
blocker.

Accommodation (simulator builds only): use a `FileBackedIdentityStore` instead of
`KeychainIdentityStore`, persisting under the app data/database dir (e.g.
`SimulatorIdentity/identity.json`). Device behavior stays on the Keychain path.
Touches `Auth/Keychain/KeychainIdentityStore.swift` and `ConvosClient+App.swift`.

## Step 4 - backend auth blocked: App Check

Symptom once an identity exists:
```
Firebase App Check debug token: '<uuid>'
HTTP 403  "App attestation failed."
```
This blocks `SessionStateMachine.authenticateBackend()` from reaching authorized.

Two options:

- Register the printed App Check debug token in Firebase (preferred) - see the
  `/firebase-token` flow.
- Or, simulator builds only (`.local` / `.dev`): return a dummy
  `defaultOverrideJWTToken` so `authenticateBackend()` follows the existing
  override path and skips App Check-backed auth.

## Verification

Expected console after the accommodations:
```
JWT override mode: skipping authentication, will use JWT from push payload
Starting message and conversation streams...
syncAllConversations completed, sync ready
```
The app reaches the Convos home screen with no error modal. Push/device
registration may still log an App Check 403 - expected, and it does not block
initial simulator use. Take a screenshot to confirm.

## Notes

- Steps 2-4 are pragmatic simulator-only accommodations from #843, not
  production implementations, and may not currently be committed on `dev`. If a
  launch works but new-convo fails, that is where to look.
- The contention workaround in Step 1 is a local escape hatch only. Genuinely
  slow expressions still get fixed in code per CLAUDE.md.
