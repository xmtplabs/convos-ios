# DTUPilot

The first Convos iOS pilot test that consumes the **XMTPDTU** Swift SDK to
drive a local `dtu-server` subprocess end-to-end — **zero XMTP backend,
zero Docker**. It exercises the "conversation list sync + newest-message
preview" scenario, which mirrors the most common binding on Convos's home
screen: a user's installation pulls two groups (one they created, one they
joined via sync) and renders each with its newest non-system message as a
preview.

## What this package does

- Declares a SwiftPM-only, macOS-only test target that depends on
  `XMTPDTU` (local-path sibling at `../../xmtp-dtu/clients/swift`).
- Spawns `dtu-server` as a subprocess, creates a universe, bootstraps two
  actors (`alice-phone`, `bob-phone`), drives a short scripted scenario,
  and asserts the newest-message projection per conversation.
- Auto-skips cleanly if the server binary can't be found, with a runnable
  `cargo build` command in the skip message.

## Why it's isolated from `ConvosCore`

`ConvosCore` targets iOS v26 / macOS v26 and pulls libxmtp, GRDB,
Firebase, and Sentry — a very different dependency surface than the
zero-dep XMTPDTU SDK. Linking them in v0.1 would either bump `DTUPilot`'s
platform floor past what `Process`-based tests need, or drag libxmtp into
a test graph that's explicitly trying to demonstrate no-XMTP viability.
The Stage 3 refactor introduces a `MessagingClient` injection seam in
`ConvosCore`; once that lands, a follow-up pilot can assert the same
scenario against a ConvosCore-hosted client backed by DTUClient instead
of the real backend.

## Running locally

```sh
# 1. Build the Rust server (one-time / after xmtp-dtu bumps).
cd /Users/jarod/Code/xmtplabs/xmtp-dtu/server
cargo build --release -p dtu-server

# 2. Run the pilot.
cd /Users/jarod/Code/xmtplabs/convos-ios-task-A/DTUPilot
swift test
```

Expected output: one test (`testConversationListAndNewestMessagePreview`)
passes. Runtime is a few seconds after SwiftPM finishes any
incremental-build work.

### Overriding the binary path

```sh
DTU_SERVER_BIN=/absolute/path/to/dtu-server swift test
```

The test's discovery chain is: `DTU_SERVER_BIN` env var first, then a
workspace-relative `../../xmtp-dtu/server/target/release/dtu-server`
resolved against the test source file (not CWD), so the test behaves the
same when invoked from the package root or the enclosing workspace.

## Running in CI

The pilot is not yet wired into `ci/run-tests.sh` — that's the next PR.
When CI is added, the recipe is:

```yaml
- name: Build dtu-server
  working-directory: ${{ github.workspace }}/xmtp-dtu/server
  run: cargo build --release -p dtu-server

- name: Run DTU pilot
  working-directory: ${{ github.workspace }}/convos-ios-task-A/DTUPilot
  env:
    DTU_SERVER_BIN: ${{ github.workspace }}/xmtp-dtu/server/target/release/dtu-server
  run: swift test
```

CI should run this on macOS (GitHub-hosted `macos-latest` works). The
pilot is macOS-only by design; see "Platform scope" below.

## Platform scope — why macOS-only?

`DTUClient.spawn(...)` uses `Process`, which isn't available on iOS. The
pilot proves the SDK is usable from Convos's Swift ecosystem as a host-
side driver for test scenarios; it's not yet exercised from the iOS
simulator. iOS consumers would use `DTUClient.connect(url:)` against a
server running on the host machine or a shared CI instance — that's the
Stage 3 iOS refactor's job, not this pilot's.

## Where to go next (Stage 3)

1. **ConvosCore injection seam.** Introduce a `MessagingClient` protocol
   in ConvosCore that today's XMTPiOS-backed implementation conforms to.
   Add a `DTUClient`-backed conformance in a test module so existing
   ConvosCore-level tests can run against `dtu-server` instead of the
   real libxmtp.
2. **iOS simulator pilot.** Run `dtu-server` on the host and point an
   iOS-simulator XCTest at it via `DTUClient.connect(url:)`.
3. **Wire contract parity tests.** Port the remaining XMTPDTU wire
   scenarios (streams, consent, permissions, admins) into Convos-flavored
   tests that assert end-to-end UI bindings.

## Files

- `Package.swift` — SwiftPM manifest, macOS v12, `XMTPDTU` via local path.
- `Tests/DTUPilotTests/ConversationListPreviewPilotTests.swift` —
  the single pilot test (one `XCTestCase`, one test method).
