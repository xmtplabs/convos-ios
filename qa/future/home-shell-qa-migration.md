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

## 4. Remaining nav-foundation work (next chunk)

- `qa/TOOLS-CLAUDE.md`: stale `scan-button` bottom-toolbar caveat + the
  `(292, 823)` coordinate.
- Markdown docs (`qa/tests/*.md`) lag the YAMLs: `18`, `04`, and especially
  `25-conversations-list-baseline.md` (documents the old toolbar:
  `app-settings-button`, `scan-button`, `filter-button`). `25-baseline` is a
  larger rewrite tied to the whole list UI.

## 5. Beyond the shell: missing coverage (later chunks)

New / changed areas with `.md` docs but no structured YAML, or no test at all:

- Agent builder / templates flow (new; large)
- Credits / subscription UI (`subscription-row`)
- Device pairing (`38-pair-device.md`, `devices-row`)
- HTML attachment tiles + zoom preview (recently shipped)
- Contacts system (`contacts-row`) and Connections (`connections-row`)
- Focus mode (assistant builder bubble states)
- `33-read-receipts.md`, `32-voice-memo-transcription.md`,
  `34-side-convo-stable-emoji.md` (md only, no YAML)
- "New Agent" pending drafts in the conversations list

Prioritize by release-criticality once the nav foundation is solid.
