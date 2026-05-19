# Connections Picker — Bundles + Backend Config (draft)

**status:** sharing for vibes-check
**owner:** louis
**date:** 2026-05-19

Heads up: this is a notepad, not a real PRD.

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

Backend-served, cached on device. App icon embedded as base64 so we don't need a CDN round-trip in the picker.

```json
{
  "version": 1,
  "services": [
    {
      "id": "google_calendar",
      "composio_slug": "googlecalendar",
      "display_name": "Google Calendar",
      "icon": {
        "format": "png",
        "base64": "iVBORw0KGgoAAAANSUhEUgA..."
      },
      "bundles": [
        {
          "id": "calendar.events",
          "title": "Events",
          "description": "View and edit events on all calendars",
          "default_enabled": false,
          "composio_actions": [
            "GOOGLECALENDAR_LIST_EVENTS",
            "GOOGLECALENDAR_CREATE_EVENT",
            "GOOGLECALENDAR_UPDATE_EVENT",
            "GOOGLECALENDAR_DELETE_EVENT"
          ]
        }
      ]
    }
  ]
}
```

Key fields on a bundle:
- `id` — stable identifier we persist on the grant
- `title` — what the user reads (bold line in the card)
- `description` — the rationale line under the title; renamed from `rationale` in earlier sketches to match Figma copy
- `default_enabled` — figma shows toggles off; flip per-bundle if we want one on by default
- `composio_actions` — what we actually send to Composio when granted

Open question: do we also want `read_only` / `write` hints per bundle so we can show a small "writes" badge on cards that mutate? Probably v2.

## Renames vs earlier scribbles

Earlier draft had `rationale`. New name: `description`. Reason: the Figma label is plainer ("View and edit events on all calendars") and `description` reads more naturally for designers writing copy. We can alias `rationale` if anyone's already coding against it.

## What the app does

- Fetch the service config JSON when the picker opens (cache it; respect cache headers).
- Render one card per bundle. Title + description + toggle.
- On Done, send a single grant containing the *bundle ids* the user toggled on. Translate to Composio action slugs at the publish boundary (same pattern as the slug-vs-canonical fix we just shipped in #771).
- Store grants keyed by `(service_id, bundle_id)`. Revoke flips them all back off.

## What the backend does

- Owns the config JSON. Versioned.
- Resolves bundle → action list when actually executing on behalf of the agent (so the device never has to know exactly which Composio actions a bundle holds — we only persist the bundle id).
- Can ship new actions inside an existing bundle without a client update.

## Stuff I'm punting on

- Localization. English-only copy for now; structure supports `{ "en": "...", "fr": "..." }` later but I'd rather not bake it in until we actually localize.
- Granting from inside a convo vs from the global connections screen — same schema, two entry points. UX of the global screen is unblocked by this.

## Asks

- Naming sanity: `description` vs `rationale` — anyone strongly prefer one? I'll go with `description`.
- Design: how many bundles per service is realistic? If it's >5 we'll want to think about scroll vs collapsing.

Comments / hot takes welcome.
