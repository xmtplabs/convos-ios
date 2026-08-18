# Connections v1 -> v2 cleanup map

**Goal:** adding an ability becomes backend-manifest-only. Today every new
service needs an ~8-line iOS PR touching up to six hand-maintained per-service
tables. This map classifies each table and its consumers, records what this
foundation PR migrates, and states the unblockers gating each remaining
deletion. Constraint: the v1 `capability_request` transcript card is still the
live consent path (including MCP abilities), so this is a staged migration, not
a big-bang deletion.

Buckets:

- **deletable-now** — genuinely dead, removable in this PR.
- **migratable** — a catalog-driven replacement exists or is introduced by this
  PR; the table degrades to a fallback and is deleted once the backend ships
  the manifest fields and the fallback window closes.
- **kept-until-\<unblocker\>** — load-bearing for a surface that has no v2
  replacement yet; the named unblocker is what retires it.

## The per-service tables

### 1. `SupportedConnections.supportedCloudServiceIds` — migratable

`ConvosCore/Sources/ConvosCore/CapabilityResolution/SupportedConnections.swift:20`

Consumers:

- `SessionManager.bootstrapCapabilityProviders` (`ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift:1040`) — seeds unlinked placeholder providers so the consent picker can offer connect-and-approve pre-OAuth.
- `ConnectionsListViewModel` (`Convos/App Settings/ConnectionsListViewModel.swift`) — filters the App Settings v1 connections list.
- `ConversationConnectionsSection` (`Convos/Conversation Detail/ConversationConnectionsSection.swift`) — same filter for conversation info.
- `AutoEnableAbilitiesService` (`ConvosCore/Sources/ConvosCore/CloudConnections/AutoEnableAbilitiesService.swift`) — v1 mirror; stands down when v2 is active.

Migration in this PR: the placeholder seed set becomes the union of this table
and the serviceIds of catalog manifests carrying `provider` fields, so a
backend-only manifest addition registers a provider with no iOS change. The
table remains the fallback for backends that predate the fields. Delete once
the backend ships `provider` on every cloud manifest and the v1 settings
surfaces retire (see kept-until entries below).

### 2. `CloudCapabilityProvider.serviceSubjectMap` — migratable

`ConvosCore/Sources/ConvosCore/CapabilityResolution/CloudCapabilityProvider.swift:45`

Consumers: `placeholder(serviceId:)` (nil without an entry — the seed is
silently skipped) and `from(_:)` (post-OAuth registration). Routes the consent
sheet: no subject, no card.

Migration in this PR: `CloudProviderDescriptor.subject` (from the manifest
`provider.subject`) wins when present; this table is the fallback. Delete with
the same condition as table 1.

### 3. `CloudCapabilityProvider.serviceCapabilitiesMap` — migratable

Same file, line 61. Absent entry defaults to `[.read]`, which silently drops
any write ask (`computeLayout` filters on `supportsCapability`).

Migration in this PR: `CloudProviderDescriptor.capabilities` (from
`provider.capabilities`) wins when present; table fallback. Delete with table 1.

### 4. `CloudCapabilityProvider.serviceDisplayNames` — migratable

Same file, line 77. Placeholder display names for the consent surfaces.

Migration in this PR: the manifest `displayName` (already localized, already
served) rides the descriptor; table fallback. Delete with table 1.

### 5. `CloudConnectionServiceNaming.displayNameOverrides` — kept-until-CON-773

`ConvosCore/Sources/ConvosCore/CloudConnections/CloudConnectionServiceNaming.swift:14`

Consumers: transcript summary lines for legacy connection events
(`ConnectionMessageSummaryFormatter`), `CloudConnectionManager.displayName`
persistence fallback. These format *historical* XMTP messages whose payloads
carry only a slug — a catalog lookup cannot rename messages already rendered on
other members' devices.

Unblocker: CON-773 (XMTP connections-metadata drain). Once legacy connection
events stop flowing and historical rendering is no longer required, delete the
override table and derive names purely from the catalog.

### 6. `CloudConnectionServiceCatalog` — kept-until-CON-802 + deep-link gate move

`ConvosCore/Sources/ConvosComposer/CloudConnectionServiceCatalog.swift:14`

Consumers:

- `DeepLinkHandler.swift:63` (`ConvosCore/Sources/ConvosComposer/DeepLinkHandler.swift`) — **load-bearing security gate**: connection-grant deep links referencing a service not in this catalog are dropped. Deleting an entry silently breaks that service's OAuth/grant deep-link return.
- `ConnectionsListViewModel` / `ConversationConnectionsSection` — v1 surfaces swapped out under `isAbilitiesV2Enabled` (`AppSettingsView.swift`, `ConversationInfoView.swift`).
- Legacy `CloudConnectionGrantRequest` card + settings grant sheet (older content type, still decoded).

Unblockers: (a) the deep-link gate must validate against the backend catalog
(or the descriptor store) instead of this table; (b) CON-802 (legacy path
retire) removes the v1 surfaces. Both, then delete.

### 7. `ConnectionServiceIcon` — kept-until-#1321-path-covers-v1-sheet

`ConvosCore/Sources/ConvosComposer/ConnectionServiceIcon.swift:18`

Consumer: `CapabilityApprovalSheetView.swift:261` (v1 approval sheet branded
icons; SF-symbol fallback otherwise). The v2 catalog already serves per-ability
icon URLs (`icon.iosUrl`, consumed by `AbilityRowComponents` via the #1321
ability-catalog icon path). Unblocker: route the v1 approval sheet's icon
through the catalog icon (or retire the sheet per the end-state below), then
delete the asset switch.

## Bucket summary

| Bucket | Count | Entries |
|---|---|---|
| deletable-now | 0 | — (verified: every table row feeds a live surface, the deep-link gate, or historical-message rendering; the sweep found no dead rows) |
| migratable (this PR starts) | 4 | supportedCloudServiceIds (seed role), serviceSubjectMap, serviceCapabilitiesMap, serviceDisplayNames |
| kept-until | 3 | displayNameOverrides (CON-773), CloudConnectionServiceCatalog (CON-802 + gate move), ConnectionServiceIcon (#1321 path coverage) |

Also kept, not a table: `AutoEnableAbilitiesService` (v1 mirror, already
flag-stood-down under v2; retires with CON-802).

## What this PR builds (the keystone)

Catalog-driven provider registration with hardcoded fallback:

- `AbilitiesAPI.Ability` decodes an optional `provider` object (`providerId`,
  `subject`, `capabilities`). Absent field: nil — old backends keep working.
- `CloudProviderDescriptor` is the typed resolution of those fields;
  `CloudProviderDescriptorStore` holds the latest catalog-derived set and
  publishes updates.
- `CloudCapabilityProvider.placeholder`/`from` and
  `CapabilityProviderBootstrap.syncCloudProviders` consult descriptors first
  and fall back to the hardcoded tables when absent.
- `LiveAbilitiesService` feeds the store on every committed catalog;
  `SessionManager` re-syncs the registry on store updates.

Backend manifest fields needed (sketch, convos-assistants — not part of this
PR):

```json
{
  "id": "googledocs",
  "version": 4,
  "displayName": { "en": "Google Docs" },
  "provider": {
    "providerId": "composio.googledocs",
    "subject": "photos",
    "capabilities": ["read", "write_create", "write_update"]
  }
}
```

Semantics: `provider` optional (absence = client fallback tables);
`providerId` must be `composio.<serviceId>`; `subject` one of the
`CapabilitySubject` raw values (`calendar`, `contacts`, `tasks`, `mail`,
`photos`, `fitness`, `music`, `location`, `home`, `screen_time`); `capabilities`
subset of `read`, `write_create`, `write_update`, `write_delete`; any change
bumps the manifest `version` (existing staleness contract). Unknown subject or
capability strings are tolerated on the wire and dropped at mapping time, so
the backend can add vocabulary ahead of old clients.

## End-state: the Entitlement Actor Model target

Product direction (Louis, grounded in the "Entitlement Actor Model" design
doc, draft 2026-07-31): consent moves out of the shared group surface and into
the member's 1:1 agent conversation, with authorization computed backend-side
per call.

Target model:

- **Connections are managed in the 1:1 agent conversation (Agent tab).**
  Connecting a calendar or mail account happens there, not via a shared group
  pill. The group is never the connect surface.
- **Escalation (cross-member use) is also negotiated in the 1:1 agent tab**,
  materializing backend-side as bounded delegations per the actor-model doc:
  six roles (trigger / actor / requester / credential-owner / beneficiary /
  approver); requester and credential-owner are platform-resolved, never
  model-supplied; ambiguity fails closed; the turn entitlement set is computed
  per call backend-side and never cached for the length of a turn; the consent
  prompt is an app surface, not chat text; delegations are bounded and
  auditable in the ability UI. The authorization matrix behind this is not
  yet implemented -- the phasing below accounts for that.
- **Group conversations carry at most a status pointer** (e.g. "waiting on
  \<member\>"). Anti-enumeration invariant: the group learns that an action is
  escalation-gated, never the owner's connection inventory.
- **All ability metadata is backend-driven.** The client may cache the catalog
  at a short TTL (deployment-scoped data), but never authorization state
  (turn-scoped -- live per call).

The catalog-driven registry this PR builds is the keystone regardless: it is
transport- and surface-agnostic (it feeds whatever surface renders consent),
and it is what makes the client's ability metadata backend-driven.

### Phasing (this rewrites the kept-until bucket's unblockers)

- **Phase 0 -- this draft.** Catalog-driven provider registration with
  hardcoded fallback; catalog stays the only client-cached ability metadata
  (short-TTL deployment scope; the existing last-known-catalog cache already
  matches this shape). No authorization state is cached today on the v2 path;
  keep it that way.
- **Phase 1 -- connection management moves to the 1:1 agent tab.** Doable on
  the current entitlements backend (begin/complete/revoke already exist).
  iOS surfaces this needs: an abilities/connections section in the agent DM
  (today the Agent tab has no connect affordance -- the v2 abilities list
  lives in App Settings and conversation info), the #1321 catalog icon path
  reused there, and deep-link routing for the OAuth return into the DM
  context.
- **Phase 2 -- escalation negotiated in the 1:1 per the actor model.**
  Blocked on the backend authorization matrix and the meta-tool family
  (`abilities_status` / `abilities_request` / `abilities_escalate`). The group
  side gains only the status-pointer surface (see dependency (b) below).
- **Phase 3 -- delete the v1 card and the per-service tables.** CON-802
  (legacy path retire) removes `CapabilityConnectPromptView`,
  `CapabilityApprovalSheetView`, the resolution pipeline behind them, and the
  kept-until tables (the deep-link gate moves to the catalog/descriptor
  store first); CON-773 (XMTP connections-metadata drain) releases the
  transcript-naming table.

### Two dependencies this phasing surfaces

- **(a) DM delivery reliability becomes consent-critical.** Once consent rides
  the 1:1 lane, a dead agent-DM stream, missing backfill, or a stale
  conversation binding (CON-803) silently breaks consent itself -- not a
  papercut but a prerequisite for phase 1. The reliability work must land
  before consent depends on the lane.
- **(b) The group-side "pending consent" state is an unbuilt product
  surface.** "Waiting on \<member\>" (without enumerating what the member has
  or hasn't connected) has no design or implementation today; phase 2 cannot
  ship without it, and it needs the anti-enumeration invariant designed in
  from the start.

Until phase 3 lands, the v1 card stays live, which is why the kept-until
bucket exists: migratable tables shrink to fallbacks now (this PR), fallbacks
delete when the backend ships `provider` fields on every cloud manifest, and
the v1 card plus its remaining tables delete at CON-802 with the deep-link
gate moved to the catalog and transcript naming resolved per CON-773.
