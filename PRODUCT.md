# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

The primary user is the group's organizer: the person in a busy iMessage group (trips, events, projects, family logistics) who ends up tracking plans, decisions, and dates by hand. They hire Doc to turn thread chaos into a shared, always-current document they no longer maintain themselves.

Secondary participants are the other group members, who never touch this app: they text the doc's phone number, or just keep talking in their iMessage thread.

## Product Purpose

Doc turns an iMessage group thread into a Google Doc that stays current. In this app, the organizer feeds the agent screenshots or pasted text from a thread (via the agent DM); the agent creates and maintains the summary document. Optionally, the group adds Doc's phone number to the iMessage thread, after which the doc stays current automatically and anyone can contribute by text.

This repository is the iOS app — the organizer's only surface. The product direction is committed: the Convos app becomes Doc's app. Success for the current phase is a working end-to-end preview; a durable success metric is an open decision.

## Positioning

Doc's agent is a native member of the group's *existing* iMessage thread — blue-bubble, via a dedicated Photon (photon.codes) iMessage line. Verified 2026-08: SMS providers (Twilio, Telnyx) cannot join an existing iMessage group at all — Apple forces a new downgraded group — so "lives inside the thread you already have" is a claim neighbors cannot truthfully copy. The output is equally deliberate: a real Google Doc the user owns, not a proprietary doc surface.

## Operating Context

- The app today is Convos ("The Agentic Messenger"): a SwiftUI XMTP messenger whose home is `Convos/Conversations List`, with `Conversation Detail` and `Conversation Creation` as the other primary surfaces. Doc's flows currently ride it as a dev preview.
- The agent platform (Worker, Hermes runtime, backend, Herald) lives in the separate `convos-assistants` monorepo; this app talks only to convos-backend.
- Dev preview mechanics: Settings ▸ Debug ▸ Doc mode resolves the newest live variant labeled "Doc," persists it as the standard Agent Variant selection, and binds it during the silent first-run join. If the shell points at an unbound or mismatched agent, enabling Doc mode replaces only that local binding and creates the correctly bound agent.
- First run proactively presents the existing native Google Docs connection and sharing sheet after the Doc agent DM is ready; OAuth and grants continue through existing app and backend APIs.
- Home keeps Google Docs readiness visible after first run and returns to the same native connection and grant flow when access is absent or revoked.
- Doc mode is production-locked and entered only with the Debug toggle. Its first-run and home shell replace the legacy tab and conversation-list UI entirely; turning it off leaves the selected runtime and existing agent conversation intact.
- Home's **For you** register surfaces unresolved agent questions above doc status. Chip answers send immediately; free-text answers send in the same gesture and restore inline if delivery fails.
- Each doc carries a fixture at the top: the contribution phone number and a CTA to text it.
- Build conventions (schemes, Secrets.swift, environments) are documented in the repo's CLAUDE.md and ENVIRONMENTS.md.

## Capabilities and Constraints

- Screenshot ingestion via vision analysis; the doc is always regenerated in full from the agent's per-thread ledger, never patched.
- The agent DM carries replaceable state snapshots, waiting items, and item-resolution events as compact JSON prefixed by `⟦doc⟧`. The client defensively parses protocol v1 and persists the latest snapshot plus unresolved items per account for cold/offline rendering.
- Organizer answers travel back through the same DM as compact JSON prefixed by `⟦ans⟧`. Both protocol prefixes are control-plane traffic and stay hidden from transcript, preview, and notification surfaces.
- Google Docs create/update/share are Composio-backed and dev-only today (production deliberately dark); OAuth scope is `drive.file` — Doc touches only documents it created.
- One shared Photon Business line (+1 628 309-5734, dev) serves all docs; group messages route by thread, direct texts route only when the sender is unambiguous. Inbound media over the line carries no bytes — images must come through this app's agent DM.
- Phone verification is the first first-run step, before Google connect, and is inbound-first: the app opens Messages pre-addressed to the line with `VERIFY <code>`; the inbound text proves number control. A verified number's first text in an unbound group binds that thread to the owner's agent automatically — no pre-registration.
- Verification is also the migration signal: re-verifying on a new agent releases the abandoned agent's bindings and routes, so Reset Doc agent is self-healing.
- Texts sent before @doc joined a group never reach it (Apple delivers no history to new members); after a group binds, the agent offers a one-time "Want me to catch up on \<group\>?" inviting screenshot backfill.
- The agent's only group-facing voice is the organizer-authorized first share and explicitly approved reshares. Doc updates never produce group texts; they land in the app via the state publish (`lastChange` on the doc card).
- User-facing copy says "agent," never "assistant."
- Terminology: a *binding* is (line, thread) → agent instance; the *fixture* is the doc-top contribution block; the *ledger* is the agent's per-thread state file.

## Brand Commitments

- The name **Doc** is committed, not a codename.
- **iMessage as the wedge** is committed: native membership in existing groups is the defining mechanism, not one channel among many.
- **Google Docs as the artifact** is committed: the user owns the output in their own account.
- The app currently ships Convos branding; whether and how it rebrands to Doc is an open decision.
- **Voice (forming, Saul-pinned 2026-08-26):** the phrase "living doc" is banned in all product copy — say "doc". The contact card identifies @doc with its number without a redundant tagline; the first share to a group is exactly "here's a doc for us (link)" (sent by the agent when @doc is in the chat, by the organizer's share sheet otherwise); subsequent group notices are "updated the doc with <~8 words max> (link)".
- **Standing visual preference (2026-08-26, revised same day):** Doc's app UI keeps the iOS category-standard structure at **Flighty's** craft level, but is styled with the **incumbent Convos design system** — the app's own tokens, colors, type treatments, and shared components — as much as possible, per Saul's correction that raw system-blue native styling "looks clunky." System-blue-everything is superseded; the Convos component library is the styling authority. The dev-preview Doc build hides legacy Convos conversations from the UI (their data still feeds the state parser).

## Evidence on Hand

- A working end-to-end preview: convos-assistants PR #3655 (agent template, Photon bridge/routing, tools, variant) and convos-ios PR #1440 (Debug create action); plan record at https://plan.ref.tools/rFrDeIyW8PWxPp1z.
- No customers, testimonials, usage metrics, or press exist yet — future work must not fabricate any.

## Product Principles

1. The thread is the source of truth; the doc is its always-current shadow — regenerate, never patch.
2. Meet the group where it already talks; never make the group move tools.
3. The user owns the artifact — a real document in their account, portable and shareable.
4. Contributing must be as light as sending a text; no app, no account, no onboarding for members.
5. Spend the group's attention sparingly — every group-facing message must be worth an interruption.
6. Consent is one gesture: anything awaiting the organizer offers approve-as-is or edit-and-approve in a single step — an edit never spawns a second approval round.
