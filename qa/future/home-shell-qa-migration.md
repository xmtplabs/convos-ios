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
  **Validated on-sim (PASS, all 6 criteria)** - YAML refined from the run
  (tap the tile body; preview toolbar verified visually, not via idb). The
  other four (32/33/34/38) remain pending on-sim validation.

## 6. First validation run (test 39, run c8ed5edc151b) - PASS

Ran the new `qa-run` workflow (`.claude/workflows/qa-run.js`) on test 39, on
iPhone 17 with the #910 build. The harness works (dispatches a `qa-runner`,
aggregates). The first attempt came back ERROR (blocked by setup); see the
environment fix below. After the fix, **test 39 PASSED all 6 criteria**: the
CLI HTML attachment renders as the `html-attachment-bubble` tile (blue page
content filling the thumbnail, not a generic file bubble), tapping the tile
body opens the full-screen WKWebView preview, and close returns with the tile
intact. `message.received (type=attachments)` confirmed.

### Environment blocker (diagnosed + fixed) - see [[project_qa_cli_libxmtp_fresh_home]]

App<->CLI MLS welcome/DM delivery failed in both directions, blocking every
multi-party test. NOT a dev-network outage (app<->app worked) and NOT the QA
code. Root cause: the convos CLI's libxmtp lagged the app's, and its `~/.convos`
home was created under the older libxmtp, leaving a stale installation the app
couldn't deliver to. Fix: build the CLI from source (matching libxmtp commit)
AND `rm -rf ~/.convos && convos init --env dev --force` (re-add `CONVOS_API_KEY`).
After that, app->CLI join delivered and the app joined (2 members), end to end.

### Findings to action

- **App bug (minor):** the HTML tile thumbnail shows the error triangle after a
  cold app relaunch - `HTMLThumbnailRenderer resuming early: load timed out`.
  The thumbnail rendered fine pre-relaunch and didn't recover within ~12s. In
  the HTML-attachment feature area (PR #878); worth a follow-up there.
- **App a11y gaps:** the `invite-qr-code` share affordance has no id
  (suggest `invite-share-button`); the `AttachmentPreviewSheet` toolbar
  controls (`attachment-preview-close`/`-sender`/`-share`) and
  `html-attachment-bubble-sender` overlay a WKWebView and aren't enumerated by
  idb - test 39 verifies them visually and taps via MCP. Adding stable ids
  would make them scriptable.
- **Docs:** `cli_process_joins` `timeout` param documented in the structured
  README (wraps `--watch` + kill; `process-join-requests` has no `--timeout`).

## 7. Still missing (later, separate PRs)

- Agent builder / templates flow (new; large)
- Credits / subscription UI (`subscription-row`)
- Contacts (`contacts-row`) and Connections (`connections-row`)
- Focus mode (assistant builder bubble states)
- "New Agent" pending drafts in the conversations list

Prioritize by release-criticality.
