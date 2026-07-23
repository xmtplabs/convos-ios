# PROTOTYPE — Agent reads a Google Doc

> **Not part of the numbered QA regression catalog** (deliberately not added to
> `qa/SKILL.md`'s Available Tests table). This is a manual verification note for
> the shared PR Preview build tied to this prototype — a human tester following
> steps in the running app, not an automated simulator spec. Delete this file
> (and its runtime-side counterpart) once the prototype is retired.

## What this tests

Whether an agent in a Convos conversation can read the content of a Google Doc,
without convos-backend or the Composio connections catalog knowing anything
about Google Docs (today only `googlecalendar` is wired into
`bundles.config.ts`). The paired `convos-assistants` PR adds two bespoke tools
(`convos_connect_google_doc`, `convos_read_google_doc`) that call Google
directly from inside the agent's own container — see that PR for the
implementation and its scope/limitations.

## Setup

1. Install the shared PR Preview build for this prototype (dev network only).
2. Open or create a conversation with an agent on that build.
3. Have a Google Doc ready in one of two sharing states:
   - **Link-shared** — "Anyone with the link can view". No further setup.
   - **Private** — get a short-lived OAuth access token yourself (e.g.
     `gcloud auth application-default print-access-token`, or the
     [OAuth 2.0 Playground](https://developers.google.com/oauthplayground)
     scoped to `documents.readonly` or `drive.readonly`). Tokens like this
     usually expire in about an hour.

## Steps — link-shared doc (no token)

1. Send the agent the doc's URL and ask it to read/summarize it, e.g. "Can
   you read this and give me the gist? <link>".
2. **Expect:** the agent calls `convos_read_google_doc` directly (no connect
   step) and replies with real content from the doc, not a refusal.

## Steps — private doc (pasted token)

1. Send the agent the doc's URL and tell it you have a private doc — ask it
   to connect it, then paste the access token when it asks (or paste both in
   one message: "Connect this doc, here's the doc link and an access token:
   <link> <token>").
2. **Expect:** the agent calls `convos_connect_google_doc`, then
   `convos_read_google_doc`, and returns real content from the doc.
3. Ask again ~1h+ later (or after revoking the token): **expect** a plain
   "couldn't read it, try a fresh token" style error — not a hang, not a
   fabricated summary.

## Things to flag as bugs (not just "prototype rough edges")

- The agent claims this is the same as connecting Calendar in Settings, or
  names the OAuth broker — it should say plainly this is a scoped prototype.
- The agent invents doc content instead of erroring when both the public
  export and (if given) the token fetch fail.
- Anything that reaches convos-backend for this flow at all — it shouldn't;
  everything here is meant to happen inside the one agent container.

## Known, accepted limitations (not bugs)

- No refresh/revoke for a pasted token; it just stops working when Google
  expires it.
- The token is stored in this one agent instance's own local state
  (rclone-synced to its private R2 sandbox), in plaintext, for as long as the
  instance lives — never sent to convos-backend, but also not encrypted at
  rest beyond whatever the instance's normal storage already gets.
- Dev/ephemeral-runtime only, per the shared-prototype system.
