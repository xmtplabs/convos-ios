# Device Abilities - Migrating Device Connections to Abilities V2

**Status**: Draft outline for discussion
**Audience**: Abilities V2 authors, ConvosConnections authors, backend team
**Related**:
- [`connections-device-vs-cloud.md`](./connections-device-vs-cloud.md) - the original device/cloud split memo
- [ADR 012](../adr/012-connections-architecture.md), [ADR 013](../adr/013-connections-resolution.md)
- PR #1174 (HealthKit re-enable for PR-build testing), #1259 (Abilities V2 live service), #1277 (V2 conversation-info flows)

## TL;DR

Abilities V2 replaces the V1 Connections surfaces wholesale when its flag flips: the App Settings list, the conversation-info section, and the picker all render the backend-served catalog, which models cloud/OAuth services only. Device connections (Health today; Calendar, Contacts, Location, etc. tomorrow) have no representation in the V2 model - no catalog entry, no entitlement shape, no connect flow, no way to extend them to an agent. The background invocation runtime keeps working for existing grants, but the moment V2 becomes the shipped surface, users can no longer see, grant, or revoke device connections.

This plan makes device connections first-class **device abilities**: they appear in the same catalog and UI, but their trust root stays the iOS permission prompt, their enforcement stays the on-device enablement store, and their execution stays the XMTP invocation path. The backend serves the manifest; it never holds or verifies device access.

## Current state: two stacks

| Axis | Cloud (Abilities V2) | Device (Connections V1) |
|---|---|---|
| Catalog | Backend-served `GET /v2/abilities` (`AbilitiesAPI.swift`) | Static `DeviceCapabilityProvider.defaultSpecs` filtered by `SupportedConnections.supportedDeviceKinds` |
| Trust root | OAuth via `ASWebAuthenticationSession`; backend holds entitlement | iOS permission prompt; `authorizationStatus` per framework |
| Entitlement | Server-owned lifecycle (`pending_auth`/`active`/`expired`/...) | Client-derived from `DataSource.authorizationStatus()` |
| Per-agent grant | `extendAbility` / `withdrawAbility` backend records + V1 metadata shim | `EnablementStore` triples `(kind, capability, conversationId)` + connection events + conversation metadata |
| Execution | Backend exec (agent calls the service server-side) | On-device: XMTP `connection_invocation` -> `DataSink.invoke()` -> `connection_invocation_result` |
| UI | `AbilitiesListScreen`, `ConversationAbilitiesSection`, `AbilityConnectSheet` (flag on) | `ConnectionsListView`, `ConversationConnectionsSection`, V1 picker (flag off) |

The UI fork is exclusive (`ConversationInfoView.prepareAgentAccessViewModels()` latches one mode), so there is no world where both surfaces render. Device abilities must live inside the V2 surface or nowhere.

## Design principles

1. **The trust root stays on-device.** iOS permission prompts are the only authorization for device data. The backend can record that a device ability exists, but it can never grant, verify, or revoke device access, and clients never treat backend state as authoritative for device entitlements.
2. **Execution stays on-device.** Agents invoke device capabilities over the existing XMTP content types; V2 backend exec never touches device data. Nothing about `ConnectionInvocationRuntime`, `HealthInvocationRouter`, or the `DataSource`/`DataSink` protocols changes.
3. **One user-facing surface.** Device abilities render in the same catalog list, conversation toggles, and connect flow as cloud abilities. No second "device connections" list survives the migration.
4. **Data minimization.** No health (or other device) data and no per-type authorization detail leaves the device. What syncs off-device is at most the coarse state V1 metadata already publishes: which kinds are connected and which agents they are extended to.

## Key design decisions

### D1. Where device abilities enter the catalog

**Options:**
- (a) Backend serves device abilities as catalog entries carrying an execution/auth marker; the client filters to kinds the binary actually links.
- (b) The client synthesizes device entries locally and merges them into the fetched catalog.

**Recommendation: (a) as the end state, (b) as the flag-gated interim.** Backend-served entries keep versioning, localization, naming, and bundle definitions in one place and give Android the same manifest for free. The client remains the gate for what actually surfaces: an entry only renders when the host links the matching per-kind `ConvosConnections` product (the `DeviceConnectionsBundle` already expresses this). Until the backend contract lands, a client-side synthesis layer behind the Abilities V2 flag unblocks all UI and flow work; the merge point is designed so swapping synthesis for served entries is a data-source change, not a UI change.

Wire impact: a new discriminator on `Ability` (for example `auth.type: "device_permission"` alongside `oauth`/`none`, or an explicit `execution: "device" | "backend"` field). `AbilitiesAPI` decoding already tolerates unknown keys, so old clients skip unrecognized fields; but old clients would still *render* a device ability they cannot fulfill, so the endpoint should support filtering (client capability query param or minimum-version gate) - backend discussion needed.

### D2. Entitlement state for device abilities

The V2 `Entitlement` is server-owned; clients "read statuses, never derive them" (`AbilitiesServiceProtocol.swift`). Device abilities invert this: only the client knows `authorizationStatus`.

**Recommendation:** entitlement state for device abilities is synthesized client-side at catalog-merge time from `DeviceConnectionAuthorizer.currentAuthorization(for:)`:

- `authorized` -> `.entitled(active)`
- `notDetermined` -> `.notEntitled`
- `denied` / `restricted` -> a needs-attention row (the `needs_reauth` shape) that deep-links to iOS Settings, since the app cannot re-prompt
- kind not linked / `unavailable` -> entry hidden entirely

The backend never stores device entitlement state. `extensionCount` for device abilities is computed locally. This keeps the privacy surface identical to today and avoids inventing a client-asserted-entitlement API the backend cannot validate.

### D3. Extension (per-conversation, per-agent opt-in)

**Options:**
- (a) Reuse the V2 `extendAbility` / `withdrawAbility` backend records for device abilities too.
- (b) Keep device extensions entirely client/XMTP-side.

**Recommendation: (b).** Device execution is XMTP-mediated, so the awareness channel agents actually need is the conversation itself - and telling the backend which agents can read a user's health data expands the privacy surface for no enforcement benefit (the backend cannot enforce device invocations anyway). A device extension therefore writes, atomically from the user's tap:

1. `EnablementStore` triples for the selected bundles' capabilities - this remains the invocation gate `ConnectionInvocationRuntime` checks.
2. The conversation-metadata awareness entry and `connection_event` message the agent runtime already reads (the device analog of `AbilityV1AwarenessShimWriter`, reusing the `ProfileMetadataWriter` choke point).

Withdrawal reverses both and, for Health, tears down any background-delivery subscriptions scoped to that conversation.

Trade-off accepted: no server-side record means `extensionCount` and cross-device visibility for device abilities are local-only (see Open questions).

### D4. Bundles for device abilities

Map `ConnectionCapability` verbs plus the background-subscription capability into user-facing bundles per kind. Health, for example:

- `read_summaries` - read/fetch operations (default on)
- `log_data` - `writeCreate` operations (default off)
- `background_updates` - background-delivery subscriptions (default off)

Bundle ids are stable strings defined with the catalog entry (D1). The mapping from bundle to capability set lives client-side next to `DeviceCapabilityProvider.defaultSpecs`, which already enumerates per-kind verbs. Note iOS permission granularity does not always match bundle granularity (HealthKit authorizes per data type); the bundle governs what the enablement store permits, the OS prompt governs what the app can read at all.

### D5. Connect flow

`AbilityConnectSheet` and `AbilitiesListViewModel` branch on the auth discriminator: `oauth` runs the existing `ASWebAuthenticationSession` path; `device_permission` runs `DeviceConnectionAuthorizer.requestAuthorization(for:)`. The V2 flow shape (connect confirm -> authorize -> bundle picker -> extended) already matches the device case; `beginEntitlement` maps to the permission prompt, `completeEntitlement` is a no-op, and "revoke" becomes "manage in iOS Settings" (the app cannot programmatically un-authorize) plus withdrawal of all extensions.

### D6. Ability identity

Device ability ids follow the existing provider-id convention: `device.health`, `device.calendar`, ... (`DeviceCapabilityProvider.providerId(for:)`). This keeps a mechanical mapping between catalog entries, `ConnectionKind`, and enablement rows, and guarantees no collision with backend-assigned cloud ids.

## What does not change

- `DeviceConnectionsBundle` / `PlatformProviders.iOS` wiring and per-kind product linkage (everything PR #1174 sets up: entitlements, purpose strings, `HealthRuntimeImpls`).
- `ConnectionInvocationRuntime`, `HealthInvocationRouter`, the background observer routine, and the three XMTP content types.
- `EnablementStore` as the sole invocation-time enforcement point.
- App Clip stays `.none` (App Clips cannot use HealthKit).
- Cloud abilities: nothing in this plan touches the OAuth/backend-exec path.

## Phases

Each phase is a shippable checkpoint (plan PR first, stacked implementation PRs per the PRD workflow).

**Phase 0 - Contract alignment (backend + iOS + Android).** Agree the catalog discriminator shape (D1), the client-filtering story for old clients, and confirm device extensions stay off the backend (D3). Exit: schema PR to `abilities.schema.json` merged, or an explicit decision to ship client-synthesis-only first.

**Phase 1 - Catalog plumbing behind the flag.** Client-side device-entry synthesis merged into `AbilitiesCatalog` after fetch; a `DeviceAbilitiesProviding` seam fed by `DeviceConnectionsBundle`; `MockAbilitiesService` scenarios covering device entries in every entitlement state. Exit: Health renders in `AbilitiesListScreen` (mock and live catalog) with correct state mapping, on a Firebase PR build stacked on #1174.

**Phase 2 - Connect and extend flows.** Device branch of the connect sheet (D5); extend/withdraw bridge writing enablement triples + awareness metadata + connection events (D3); background-delivery bundle arm/disarm; needs-attention row for denied/restricted with the iOS Settings deep link; foreground refresh of authorization state. Exit: end-to-end on a physical device - add Health via the V2 UI, agent invokes `fetch_summary_last_24h` and `subscribe_background_delivery` over XMTP, withdraw tears down the subscription.

**Phase 3 - Agent-facing surfaces.** Agent builder reads the merged catalog instead of `SupportedConnections.supportedCases`; the `capability_request` flow (agent-posted card) routes device kinds into the V2 connect sheet; verify agent-runtime awareness reads the device metadata entries correctly in both flag states. Exit: an agent can request Health and the full request -> connect -> extend -> invoke loop closes under the V2 flag.

**Phase 4 - Retirement and flip sequencing.** Migrate any live V1 device grants (enablement rows are already the source of truth; this is a metadata rewrite, not a data migration); remove `SupportedConnections` device paths, `ConversationConnectionsSection` device branches, and the V1 device picker code; fold this into the Abilities V2 default-flip checklist so the flip cannot ship Health-less if #1174's App Store posture lands first. Exit: V1 device surfaces deleted, single code path.

## Open questions

1. **Backend appetite for D1(a)** - does the catalog carry device entries, and how do pre-device-aware clients get filtered? (Blocker for Phase 0.)
2. **Cross-device semantics.** Enablement rows are local GRDB; an extension made on phone A does not exist on phone B, while cloud entitlements are account-level. Do we accept per-device state for device abilities (probably yes - the authorization is inherently per-device), and how does the UI communicate it?
3. **HealthKit per-type authorization vs bundle granularity** (D4) - is bundle-level consent honest enough, or do we surface per-type state in the needs-attention flow?
4. **App Review posture** - #1174's open question stands: visible in-app Health functionality is required before any of this rides to the App Store. The V2 catalog UI may itself be the answer (Health gets a real, visible settings surface), worth raising with review guidance in hand.
5. **`entitlementsUnavailable` interplay** - when the backend catalog is stale or unavailable, device entries are still fully knowable locally. The merge must keep device rows authoritative while cloud rows go `.unknown`; confirm this does not violate the `AbilitiesCatalog` coherence invariants.

## Risks

- **Two entitlement truth models in one list.** Cloud rows are server-truth, device rows are client-truth. The merge layer is the only place allowed to know the difference; if that leaks into views, every surface grows dual-path logic. Mitigation: normalize to `EntitlementState` at the merge boundary, keep `AbilitiesServiceProtocol` the single vocabulary.
- **Withdraw/background-delivery races.** Withdrawal must unsubscribe background delivery before removing enablement rows, or a wake-up can fire against a revoked grant. The invocation gate catches it (fails closed), but the sequencing should be explicit and tested.
- **Old clients rendering device abilities they cannot fulfill** if the backend ships catalog entries before client filtering exists (D1). Sequence the schema change behind the client capability signal.
- **Flag-flip coupling.** If the V2 default flip ships before Phase 3, Health regresses silently for users. The flip checklist must gate on device-abilities readiness (Phase 4 exit) or explicitly accept a Health-less window.

## Testing

- Mock-first, matching the V2 pattern: `MockAbilitiesService` device scenarios drive all UI states without HealthKit.
- Unit: catalog merge (including `entitlementsUnavailable` interplay), extend/withdraw bridge atomicity, bundle-to-capability mapping, authorization-state mapping.
- The existing ConvosConnections suites (110 tests) and `ConnectionInvocationRuntime` tests must pass unchanged - the runtime is deliberately untouched.
- E2E on physical device per Phase 2/3 exits; the DEBUG connection injector remains the simulator story for payload rendering.
