# Convos iOS Frontend Load-Testing Harness

Fills a **real Convos installation on a physical device** with dense, realistic
content and (later slices) sustains configurable churn, to measure how the app
frontend degrades. Terminal-side; uses `@xmtp/convos-cli` as a library plus the
`agent serve` loop for the one-time device bootstrap.

This is **not** a backend load test. It drives the network so the app receives
real groups, members, and messages exactly as it would from real users.

## How enrollment works (why there are no app changes)

The Convos app uses a single stable inbox per install (ADR 011) and
adder-vouching consent (a group is auto-promoted to the main list when its
creator **or adder** is a non-blocked contact). So the device only participates
**once**:

1. **Bootstrap (one QR scan, or one invite URL).** By default the controller
   creates a control group and prints its invite QR. You scan it once on the
   phone. When the phone joins, the controller posts a greeting and waits for you
   to reply with a text message from the device before continuing, then publishes
   its own profile as a regular user (not an agent). That round-trip makes the
   controller a non-blocked contact on the phone (so it shows up in the contact
   list and vouches for later groups) and lets the harness learn the phone's inbox
   id.

   Alternatively, pass `--invite-url` with an invite generated **in the app**
   (create a conversation on the phone, share its invite link). The controller
   joins that invite instead of serving its own QR: the phone never scans, the
   phone's inbox id is the invite's creator (no round-trip needed), and joining +
   the same regular-user profile republish makes the controller a non-blocked
   contact just like the QR flow. Keep the app open on the matching env while the
   controller's join request is processed.
2. **Direct fan-out.** For every other group, the controller calls
   `addMembers([phoneInboxId])`. The MLS welcome syncs the group to the phone and
   adder-vouching lands it in the main conversations list — no further scans.

## Prerequisites

- `@xmtp/convos-cli` on PATH (`convos`). Install: `npm i -g @xmtp/convos-cli`.
- Node 20+ and this package's deps: `npm install` (in this directory).
- The Convos app built to a physical device on the **matching environment**:
  - `env: dev` -> build the **Convos (Dev)** scheme (hosted `api.dev.convos.xyz`,
    XMTP dev network). Works anywhere; keep the load gentle (shared infra).
  - `env: local` -> build **Convos (Local)** + run the local XMTP node
    (`../../dev/up`, ports 5555/5556) with the device on the Mac's Wi-Fi. Only for
    heavy/extreme.

## Usage

```bash
# Smallest end-to-end run (Dev network). Scan the QR when prompted.
npm run loadtest -- run --preset light

# Bootstrap from an invite made in the app instead of scanning a QR. Quote the
# URL so the shell doesn't split on `&`. Keep the app open to accept the join.
npm run loadtest -- run --preset light --invite-url "https://popup.convos.org/v2?i=<slug>"

# Override any config axis
npm run loadtest -- run --preset light --set groups.count=30 --set backfill.rate.perGroupMsgsPerSec=3

# Stop after a phase (provision | bootstrap | create | enroll | backfill)
npm run loadtest -- run --preset light --phase-until enroll

# Resume an interrupted run (idempotent; skips completed work)
npm run loadtest -- resume --run-id loadtest-light-2026...

# Inspect run state
npm run loadtest -- status --run-id loadtest-light-2026...

# After the run: export convos.log from the app (Debug menu -> Export Logs),
# then parse [PERF] lines into CXDB for regression comparison
npm run loadtest -- report --run-id loadtest-light-2026... --log ~/Downloads/convos.log
```

## What each run produces

Everything lives under `runs/<run-id>/` (gitignored):

- `homes/vu-<n>/` — one `CONVOS_HOME` per virtual user (vu-0 is the controller,
  vu-1.. are the reusable member pool). Each is one XMTP inbox.
- `manifest.json` — atomic checkpoint of every group's state
  (`planned -> created -> phone-added -> backfilled`), the cached phone inbox id,
  the VU registry, and counters. This is the resume ground truth.
- `device-perf.ndjson` — parsed `[PERF]` samples after `report`.

## Configuration axes (severity)

See `presets/*.yaml`. Key axes: group count (the un-paginated conversations-list
cost), size distribution (empty groups through the 150-member cap), per-group
message counts (exercises the 50-message pagination window), content mix
(short/medium/long/emoji/link; replies/reactions/attachments in later slices),
send rates with jitter, and (later slices) sustained churn, metadata/profile
churn, and typing/read-receipt noise.

## The churn phase (sustained spam)

After backfill, the `churn` phase keeps degrading the app for `churn.durationMin`
minutes (or until Ctrl-C when `durationMin: 0`). It's a rate-driven accumulator
scheduler over these axes, each configurable per preset:

- **messages** at `aggregateMsgsPerSec`, scaled by scheduled **bursts**
  (`bursts.everyMin/multiplier/durationS`), weighted toward **hot groups**
  (`hotGroupFraction`). Content is the full mix: text/emoji/link/reply/reaction.
- **typing** indicators (`typingNoisePerMin`) and **read receipts**
  (`readReceiptsPerMin`) — silent, but exercise stream processing.
- **metadata churn** (`metadataChurnPerHour`) — group renames / descriptions.
- **profile churn** (`profileChurnPerHour`) — member VUs change their display
  name (ProfileUpdate), forcing the app to re-render sender identities.
- **membership growth** (`membershipGrowthPerHour`) — adds member VUs, up to 150.
- **new groups** (`groups.duringRunPerHour`) — create + direct-add the phone
  mid-run (loops the enrollment mechanic; no rescan).

Backfill and churn share one content generator, so both send the full mix:
text (short/medium/long), emoji, links, replies, reactions, and — when an
upload provider is configured — image attachments (see below). Without a
provider, attachments degrade to text.

## Image attachments

Generated PNGs of random pixels (valid, decodable, byte-size controllable via
`backfill.media.imageTargetBytes`) are encrypted, uploaded, and sent as remote
attachments — exercising the app's 10MB->2048px/1MB compression and image cache.
This needs an **upload provider**, so it only fires on runs configured with one
(local stack MinIO / convos-api). See the commented `upload:` block in
`presets/heavy.yaml`. On plain Dev runs, attachments fall back to text.

## Teardown

`teardown` removes the phone from every group so the device's conversation list
clears without an app reinstall (the groups themselves are left intact):

```bash
npm run loadtest -- teardown --run-id loadtest-...
```

Messages are sent by a random member of each group (controller or a member VU),
so sender profiles vary. Actions dispatch through a bounded concurrency pool and
shed under backpressure (logged). Ctrl-C stops gracefully; a second Ctrl-C forces.

```bash
# Heavy preset runs 60 min of churn on the local node after backfilling 120 groups
npm run loadtest -- run --preset heavy
# Stop before churn:
npm run loadtest -- run --preset heavy --phase-until backfill
```

## Status / slices

- **Done:** provision -> bootstrap (QR once, or `--invite-url`) -> create -> enroll (direct-add +
  adder-vouching, with post-add membership verification) -> backfill (full
  content mix) -> **churn** (messages/replies/reactions/typing/read-receipts/
  metadata/profile/membership-growth/new-groups, bursts, hot groups,
  multi-sender, image attachments). Plus `teardown`. Verified on a physical
  device through enroll.
- **Next:** video attachments (ffmpeg fixtures), the `conversations.list.render`
  [PERF] emitter, and a CXDB `compare` regression workflow across presets.

## Notes / guardrails

- The home SQLite DB is single-owner: the bootstrap `agent serve` fully stops
  before the library opens the same home. Don't run two owners on one home.
- Only circulate invite URLs captured verbatim from serve — never templated
  (invalid signatures trigger the app's spam-blocking).
- Never `../../dev/down` or tear down the shared Docker stack as cleanup; other
  sessions share it.
