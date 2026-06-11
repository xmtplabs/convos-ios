# Connections Picker — Bundles + Backend Config (draft)

**status:** approved
**owner:** louis
**date:** 2026-05-26
**related:** [capability-resolution-flows.md](capability-resolution-flows.md) (how the picker gets triggered — agent sends a capability request, device opens the sheet)

## The thing

Today the connections sheet shows raw capability verbs (read / write / etc) per Composio action. That's fine for engineers, not great for humans. We want one card per *intent* the user actually has — "Events", "Files", "Drafts" — and behind the scenes that one card flips a bundle of Composio actions on/off.

Figma: <https://www.figma.com/design/m2Te49zs8hriZdzmtLVTEu/Convos-26?node-id=1846-18062>

The card has:
- a **title** (e.g. "Events")
- a **description / rationale** under it (e.g. "View and edit events on all calendars")
- a toggle per row — the sheet is scoped to one service, but a service typically exposes several permission rows, and each row's toggle could fan out to multiple Composio actions under the hood

That's it. No separate read/write switches in the basic view, unless we want to surface it to the user.

## Why bundles

A few reasons piling up:

1. **Users don't think in CRUD.** "Events" is a thing. "GOOGLECALENDAR_CREATE_EVENT + GOOGLECALENDAR_UPDATE_EVENT + GOOGLECALENDAR_DELETE_EVENT + GOOGLECALENDAR_LIST_EVENTS" is not a thing.
2. **Composio churn.** Composio adds/renames actions. If the UI hard-codes action lists, every change is an app release. Bundles let backend re-map without shipping iOS.
3. **One toggle UX.** The Figma is intentionally simple — one toggle per row. Bundles are the only way to keep it that simple while still granting multi-action access.
4. **Future scopes / federation.** Same bundle id ("calendar.events") survives even if we move off Composio later.

## Schema (draft)

Backend-served, cached on device (`GET /v2/connections/services`, served with `Cache-Control: private, max-age=300`). All wire JSON is camelCase. An `icon` (base64-embedded, so no CDN round-trip in the picker) is optional in the schema and omitted in v1 — format TBD. All user-facing strings (`displayName`, `title`, `description`) are localized maps with `en` as the guaranteed fallback — single code path, no migration when we add more locales later.

Contract source of truth: convos-backend `docs/schemas/connections-services.schema.json` + `docs/schemas/connection-grant.schema.json`.

```json
{
  "services": [
    {
      "id": "googlecalendar",
      "composioSlug": "googlecalendar",
      "version": 2,
      "displayName": { "en": "Google Calendar" },
      "bundles": [
        {
          "id": "calendar.events",
          "title": { "en": "Events" },
          "description": { "en": "View and edit events on all calendars" },
          "defaultEnabled": false
        },
        {
          "id": "calendar.events.read",
          "title": { "en": "View events" },
          "description": { "en": "View events on all calendars" },
          "defaultEnabled": false
        }
      ]
    }
  ]
}
```

Key fields:
- `services[].version` — service-level version; bumped whenever *anything* about that service changes (icon, copy, any bundle's actions). Sent in connection messages so the assistant can detect stale clients (see Versioning below).
- `bundles[].id` — stable identifier we persist on the grant
- `bundles[].title` — localized map; bold line in the card
- `bundles[].description` — localized map; rationale line under the title (renamed from `rationale` to match Figma copy)
- `bundles[].defaultEnabled` — figma shows toggles off; flip per-bundle if we want one on by default

Composio action slugs are **not** in the response — the backend strips them from the served config and resolves bundle → actions itself at exec time. Slugs never reach a client.

Localized strings always carry at minimum an `en` key. Renderer is:

```swift
func localized(_ map: [String: String], locale: Locale) -> String {
    map[locale.languageCode] ?? map["en"] ?? ""
}
```

Open question: do we also want `read_only` / `write` hints per bundle so we can show a small "writes" badge on cards that mutate? Probably v2.

## Versioning + self-healing clients

We query the service config out of band (separate from the conversation). That means a device can be on `googlecalendar` version `1` while the assistant has been upgraded to expect version `3`. To handle this without baking the config into every conversation, every connection message carries the service id (as `toolkit`), the granted bundle ids, **and** the service version the device knows about — matching the shipped `POST /v2/connections/grants` body:

```json
{
  "toolkit": "googlecalendar",
  "serviceVersion": 2,
  "bundleIds": ["calendar.events"]
}
```

On the HTTP path, staleness is caught at grant time: an unknown/stale bundle id is rejected with **400 `{"code": "unknown_bundle", "bundleId": "<the bad id>"}`** — the client refetches `/services` and re-presents the picker against the fresh catalog.

Versioning is **per-service**, not per-bundle. Connection messages always reference a single service, so the wire cost is the same as per-bundle versioning, but the backend only has to bump one number when anything about that service changes (icon, copy, any bundle's actions). Coarser than per-bundle, but avoids the storm-of-invalidations problem of a top-level config version. Trade-off chosen: small extra refresh churn for any change inside a service, in exchange for much simpler backend bookkeeping.

If the assistant sees a stale version, it returns a `stale_resource` status on the existing `CapabilityRequestResult` codec (inline — no side-channel event), telling the device which services to refresh:

```json
{
  "status": "stale_resource",
  "staleServices": [
    { "id": "googlecalendar", "expectedVersion": 3 }
  ]
}
```

Payload keys are camelCase to match the existing `CapabilityRequestResult` codec's CodingKeys — agent team to confirm the worker side emits camelCase too.

Device refetches that service's config, retries the capability call. Self-healing, one extra round-trip in the worst case. Reuses the codec we just stabilized in #771 — no new top-level event type.

## Renames vs earlier scribbles

Earlier draft had `rationale`. New name: `description`. Reason: the Figma label is plainer ("View and edit events on all calendars") and `description` reads more naturally for designers writing copy. We can alias `rationale` if anyone's already coding against it.

## What the app does

- Fetch the service config JSON when the picker opens (`GET /v2/connections/services`; cache it — the backend serves `Cache-Control: private, max-age=300`).
- Render one card per bundle. Title + description + toggle.
- On Done, send a single grant containing the *bundle ids* the user toggled on (`bundleIds` + `serviceVersion`). No slug translation on device — the backend resolves bundles to Composio actions at exec.
- On 400 `unknown_bundle`: refetch `/services`, re-present the picker, retry once.
- Store grants keyed by `(serviceId, bundleId)`. Revoke flips them all back off.

## What the backend does

- Owns the config JSON. Versioned.
- Resolves bundle → action list when actually executing on behalf of the agent (so the device never has to know exactly which Composio actions a bundle holds — we only persist the bundle id).
- Can ship new actions inside an existing bundle without a client update.

## Stuff I'm punting on

- Per-bundle `read_only` / `write` hints surfaced as badges. v2.
- Multi-locale launch. Structure supports it day one (`{ "en": "...", "fr": "..." }`), but copy is en-only until we actually localize.

## Asks

- Naming sanity: `description` vs `rationale` — anyone strongly prefer one? I'll go with `description`.
- Design: how many bundles per service is realistic? If it's >5 we'll want to think about scroll vs collapsing.

Comments / hot takes welcome.
