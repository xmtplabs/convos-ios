# QA Migration: Home Shell Rework (PR #910) + Suite Refresh

Tracking doc for bringing the QA suite back in line with the current app.
This stack sits on top of PR #910 ("Home: standard tab bar, builder bar
opposite the tabs"), which reworks the home shell that nearly every test
navigates through. Beyond the shell, large new feature areas have no
coverage at all.

## 1. Home shell changes (PR #910)

The home is now a standard SwiftUI `TabView`:

- Two tabs: **Chats** (`message.fill`) and **Stuff** (`square.grid.2x2.fill`),
  selected by label. The **Search** tab was removed.
- Tab bar is at the bottom on iPhone, top on iPad.
- Agent builder bar pins to the edge opposite the tab bar
  (`agent-builder-bar-expanded` / `-collapsed`); a compact
  `toolbar-add-agent-button` replaces it once scrolled away.
- Compose lives in the shared toolbar (`compose-button`, unchanged id).
- App settings open from the `app-indicator-pill` (top-leading), not a
  settings tab/gear.

### Old -> new navigation map

| Concern | Old (in tests) | New |
|---|---|---|
| Tabs | custom `ConvosTabBar`, Search tab | standard TabView: Chats + Stuff; Search removed |
| Open settings | `app-settings-button` / `convos-settings-button` | `app-indicator-pill` -> `AppSettingsView` sheet |
| Settings rows | `settings-view` | `my-info-row`, `devices-row`, `contacts-row`, `connections-row`, `subscription-row`, `delete-all-data-button` |
| Dismiss settings | `close-app-settings` | swipe-down (interactive dismiss) |
| Scan / paste join | bottom-toolbar `scan-button` | removed; join via camera QR or deep-link URL - see section 3 |
| Compose | `compose-button` | unchanged |

All of `app-settings-button`, `convos-settings-button`, `close-app-settings`,
`scan-button`, `settings-view`, `search-tab` are gone from the app (0 refs).

## 2. Done in this chunk (nav foundation)

- `qa/RULES.md`: added "Home Shell & Navigation" section (authoritative
  new map); fixed the toolbar auto-probe note (dropped `scan-button`).
- `qa/tests/structured/README.md`: updated the `screen` prerequisite table
  for the new shell (settings via pill, Chats/Stuff tabs, Search gone).
- Settings navigation fixed in structured YAMLs:
  - `18-delete-all-data.yaml` (entry id + header note)
  - `25b-global-defaults.yaml` (entry id)
  - `14-profile.yaml` (entry id x2; `close-app-settings` -> swipe-down x2)

## 3. Scan / paste-join flow (done)

Joining is now: device-camera QR scan (not automatable on the simulator),
or opening a deep-link invite URL (`sim_open_url`, the automatable path -
test 03). The old bottom-toolbar `scan-button` / in-app paste-in-scanner
entry was removed and may be re-enabled later.

- `04-invite-join-paste.yaml`: marked `blocked: true` (preserved for when
  the scan button returns; URL-join is covered by test 03).
- `22-rejoin-existing-conversation.yaml`: dropped the `rejoin_via_paste`
  step; keeps the deep-link rejoin.
- `24-pending-invite-recovery.yaml`: already deep-link only (`sim_open_url`)
  - no change needed.
- `RULES.md`: "Joining a conversation" section + multi-sim example now use
  the deep-link path. New `blocked` test convention documented in
  `structured/README.md`.

## 4. Foundation cleanup (done)

- `qa/TOOLS-CLAUDE.md`: the "bottom-toolbar caveat" is now a "toolbar
  caveat" - compose moved from `.bottomBar` to `.topBarTrailing`; dropped
  the stale `scan-button` + `(354,823)`/`(292,823)` coords.
- `.pi/skills/...` references in the QA docs are valid (that dir exists) -
  left as-is.
- Markdown docs reconciled with the YAMLs: `18` (settings entry), `22`
  (dropped paste-rejoin), `04` (blocked banner), `25-conversations-list-
  baseline.md` (stale banner; see below).

- **Test 16 `conversation-filters`**: marked `blocked: true`. The
  conversations-list filter picker (`filter-button`) is not currently
  surfaced (removed around the Agent Builder work #830); filter logic
  remains in `ConversationsViewModel`. Filters may be re-added later -
  re-enable then. (`stuff-filter-button` is a separate Stuff-tab control.)

### Still open

- **`25-conversations-list-baseline.md`** - bannered as stale but needs a
  full re-capture against the #910 list/shell (old toolbar, tabs, filter).

## 5. New coverage added in this PR

Structured YAMLs authored code-read (against actual app behavior + real
identifiers), pending on-sim validation:

- `32-voice-memo-transcription.yaml` - single device + CLI. Built against
  actual behavior (inline transcript, tap opens `VoiceMemoTranscriptSheet`,
  no inline chevron expand, no expansion-persistence store, no retry
  capsule). The `32-*.md` describes those unshipped features and is
  bannered as aspirational; the YAML is authoritative.
- `33-read-receipts.yaml` - two devices + CLI. `read-receipts-toggle` and
  `read-receipt-avatars` confirmed real (the md's "needs identifier" note
  was stale). Setting reached via app-indicator-pill -> "Customize".
- `34-side-convo-stable-emoji.yaml` - two devices. Uses `cli_inspect_invite`
  (added to the README action vocab) for an exact emoji/metadata cross-check.
- `38-pair-device.yaml` - two devices. Real revoke controls are
  `stale-device-sheet` + `hold-to-delete-device-button` (the md's
  `stale-device-banner` / `hold-to-reset-device-button` do not exist). Uses
  the `pairing.pairing_url_created` event to grab the URL. Auth-probe and
  iCloud-keychain checks omitted (not expressible via the QA action
  vocabulary - debug menu / Settings.app).
- `39-html-attachment.{md,yaml}` - new test. Single device + CLI. Tile id
  `html-attachment-bubble`, preview sheet `attachment-preview-close` /
  `-share` / `-sender`. Needs the CLI upload provider (`CONVOS_API_KEY`).

## 6. First validation run (test 39, run c8ed5edc151b)

Ran the new `qa-run` workflow (`.claude/workflows/qa-run.js`) on test 39 only,
on iPhone 17 with the #910 build. The workflow harness worked (dispatched a
`qa-runner`, ran ~15 min, aggregated). Test 39 itself came back ERROR -
**blocked by setup, not a feature defect**:

- No shared app<->CLI conversation could be established in **either**
  direction on the dev XMTP network: app-side `invite.join_request_sent`
  fired but the CLI's `process-join-requests --watch` never received the DM
  (member count stayed 1 across 4 attempts); reverse `add-members` succeeded
  server-side (count -> 2) but the app never received the MLS welcome (group
  topic never appeared, app stuck on "Verifying") even after relaunch+sync.
  This blocks every multi-party test (02/03/04/33/34/38/39, ...) until the
  delivery issue is resolved - likely a dev-environment / sync problem, worth
  a manual check or retry before another run.
- App-level log noise during the run: recurring
  `auto reveal preference: conversationNotFound`, `refresh credit balance:
  forbidden`, `Sentry DSN is empty`.

### Findings to action

- **App a11y gap:** the share affordance inside `invite-qr-code` (new-convo
  QR view) has no `accessibilityIdentifier` and isn't enumerable by idb;
  recommend adding `invite-share-button`. The runner read the invite URL from
  the CLI instead.
- **Docs:** `cli_process_joins` `timeout` param is now documented in the
  structured README (it wraps `--watch` + kill; `process-join-requests` has
  no `--timeout` flag).

## 7. Still missing (later, separate PRs)

- Agent builder / templates flow (new; large)
- Credits / subscription UI (`subscription-row`)
- Contacts (`contacts-row`) and Connections (`connections-row`)
- Focus mode (assistant builder bubble states)
- "New Agent" pending drafts in the conversations list

Prioritize by release-criticality.
