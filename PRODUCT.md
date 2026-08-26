# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

The primary user is the group's organizer: the person in a busy iMessage group (trips, events, projects, family logistics) who ends up tracking plans, decisions, and dates by hand. They hire Doc to turn thread chaos into a shared, always-current document they no longer maintain themselves.

Secondary participants are the other group members, who never touch this app: they text the doc's phone number, or just keep talking in their iMessage thread.

## Product Purpose

Doc turns an iMessage group thread into a living Google Doc. In this app, the organizer feeds the agent screenshots or pasted text from a thread (via the agent DM); the agent creates and maintains the summary document. Optionally, the group adds Doc's phone number to the iMessage thread, after which the doc stays current automatically and anyone can contribute by text.

This repository is the iOS app — the organizer's only surface. The product direction is committed: the Convos app becomes Doc's app. Success for the current phase is a working end-to-end preview; a durable success metric is an open decision.

## Positioning

Doc's agent is a native member of the group's *existing* iMessage thread — blue-bubble, via a dedicated Photon (photon.codes) iMessage line. Verified 2026-08: SMS providers (Twilio, Telnyx) cannot join an existing iMessage group at all — Apple forces a new downgraded group — so "lives inside the thread you already have" is a claim neighbors cannot truthfully copy. The output is equally deliberate: a real Google Doc the user owns, not a proprietary doc surface.

## Operating Context

- The app today is Convos ("The Agentic Messenger"): a SwiftUI XMTP messenger whose home is `Convos/Conversations List`, with `Conversation Detail` and `Conversation Creation` as the other primary surfaces. Doc's flows currently ride it as a dev preview.
- The agent platform (Worker, Hermes runtime, backend, Herald) lives in the separate `convos-assistants` monorepo; this app talks only to convos-backend.
- Dev preview mechanics: a per-PR agent variant (Settings ▸ Debug ▸ Agent Variant ▸ Doc) binds at agent-create; on the Doc variant any newly created agent boots as Doc. A Debug "Create Doc agent" action uses the same bare agent join as first run so the selected variant supplies its hard-coded template.
- First run proactively presents the existing native Google Docs connection and sharing sheet after the Doc agent DM is ready; OAuth and grants continue through existing app and backend APIs.
- Doc mode is production-locked and entered with the Debug toggle or a recognized Doc agent variant. Its first-run and home shell replace the legacy tab and conversation-list UI entirely.
- Each doc carries a fixture at the top: the contribution phone number and a CTA to text it.
- Build conventions (schemes, Secrets.swift, environments) are documented in the repo's CLAUDE.md and ENVIRONMENTS.md.

## Capabilities and Constraints

- Screenshot ingestion via vision analysis; the doc is always regenerated in full from the agent's per-thread ledger, never patched.
- The agent DM carries replaceable state snapshots as compact JSON prefixed by `⟦doc⟧`. The client defensively parses protocol v1, persists the latest snapshot per account for cold/offline rendering, and suppresses all prefixed messages from transcript, preview, and notification surfaces.
- Google Docs create/update/share are Composio-backed and dev-only today (production deliberately dark); OAuth scope is `drive.file` — Doc touches only documents it created.
- One shared Photon Business line (+1 628 309-5734, dev) serves all docs; group messages route by thread, direct texts route only when the sender is unambiguous. Inbound media over the line carries no bytes — images must come through this app's agent DM.
- The agent's only group-facing voice today is "\<name\> updated the doc: \<link\>" on meaningful changes. **Open decision:** additional outbound allowances are under consideration — treat silence-in-groups as current posture, not doctrine.
- User-facing copy says "agent," never "assistant."
- Terminology: a *binding* is (line, thread) → agent instance; the *fixture* is the doc-top contribution block; the *ledger* is the agent's per-thread state file.

## Brand Commitments

- The name **Doc** is committed, not a codename.
- **iMessage as the wedge** is committed: native membership in existing groups is the defining mechanism, not one channel among many.
- **Google Docs as the artifact** is committed: the user owns the output in their own account.
- The app currently ships Convos branding; whether and how it rebrands to Doc is an open decision. No product voice has been established.
- **Standing visual preference (2026-08-26):** Doc's app UI is the iOS category standard played straight — system-native vocabulary (system materials, large titles, SF, semantic colors, one tint, SF Symbols), no invented visual world, executed at **Flighty's** craft level: data-rich glanceable status inside pure platform conventions. Tint is system blue until the rebrand decision. The dev-preview Doc build hides legacy Convos conversations entirely.

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
