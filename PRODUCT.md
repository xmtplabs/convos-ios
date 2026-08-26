# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People who want one useful, living document for every group in their life without asking the group to learn a new tool.

## Product Purpose

Convos lets anyone add `@doc` to a group and give that group a living workspace. People keep talking normally; `@doc` listens with permission, turns the conversation into useful docs, sheets, and calendar coordination, and keeps those things current.

Success means a new user understands the product in ten seconds: **Turn anything into a group doc.** The intelligence and model infrastructure remain underneath that promise.

## Positioning

The home screen is the `@doc` product, not a Convos dashboard. It does one job: let the user name what a group should keep track of, give `@doc` screenshots, links, messages, files, or voice, and receive one living document that can be shared anywhere. Beneath the maker is only the user's recent document library. Conversations, personal context, settings, and advanced engines remain reachable through secondary navigation without competing with the loop.

The growth loop begins in the output. Every shared group doc carries a compact **Made by Convos** header and this invitation: “You can text `@doc` directly at +1 309-555-5555 to add anything or ask anything about this doc. You can also add me to your group chat to remember, share, research, or add anything to this group.” The document is useful without installing Convos; the invitation lets the rest of the group make it multiplayer from the chat they already use.

## Operating Context

- The user lands on `@doc` every time they open the app. The first viewport contains one Lava maker, one plain-language input, one attachment action, and one black **Make the doc** action.
- The compact header shows the `@doc` identity, the user's profile, and one native overflow menu. The overflow contains New doc, Your docs, All convos, All my things, Start a new convo, Join a convo, and Settings.
- Home has no persistent agent dock, conversation feed, briefing dashboard, widget grid, or provider roster. Those capabilities remain available after an explicit navigation choice.
- The profile image opens **All my things**, the private library spanning the user's loaded Convos plus anything deliberately shared in from another app.
- Contacts are selected in the invite flow for a conversation rather than occupying a permanent bottom-level destination.
- Home begins with one saturated promise: **Turn anything into a group doc.** The user can type what the group should track or add a source immediately. **Make the doc** opens the stable `@doc` workspace with that intent staged. Directly below, **Your docs** shows up to three recent document-like items with rich previews, source provenance, Open group, and Share anywhere. A single See all action opens the complete doc roster.
- The **All my things** Home card opens a dedicated personal library for the editable contact card, photos, links, files, connections, automatically detected useful message details, and supported assets from loaded convos by type and provenance. Items explicitly shared into Convos from another app join the same searchable private library. Edit is a distinct action on that destination. The card's iMessage, WhatsApp, and Telegram actions lead to choosing an agent that can join another group; they do not imply passive cross-app ingestion.
- Useful details are not contact-card fields: Your context shows compact Addresses, Phone numbers, Email, and All useful details filter rows, while the All Context sheet renders every indexed fact as a searchable full-width card with its source message, sender, convo, time, source-convo link, sender-message action, and share action.
- **Your `@docs`** is one roster visibly separated into **Docs you control** and **Docs shared with you**. Each verified group agent is presented as the smart doc for that group and belongs to the human who added it. A doc profile is the single control center for where it can listen, speak, use connected services, and participate. These permissions remain scoped to that exact doc and group rather than generic group settings.
- The first section of every doc profile is **Add `@doc` anywhere**. It shows the published phone number, copy actions, and concrete iMessage, WhatsApp, and Telegram instructions. **Connections** such as Gmail, Google Calendar, Google Docs, and Sheets live on the doc profile, followed by group-specific participation and connection permissions.
- Advanced engines may be connected from the `@doc` menu, but provider setup is secondary. Codex, Town, Tasklet, Grok Bot, and future providers route requests behind the stable `@doc` identity. Credentials, provider-specific capabilities, prompts, transcripts, and results remain private unless the user deliberately shares an output.
- Personal-agent identity is social only by explicit opt-in. “Show what agents I use on my profile in Convos” publishes a bounded list of provider identifiers such as Codex, Town, or Grok; it never publishes credentials, prompts, conversations, context, tools, results, or activity. Provider rows on a member profile open the existing Bring personal agents directory at that provider, and the setup CTA opens the complete directory. When synchronized membership proves that a member invited a verified group agent, their profile may say they set up that agent for the convo and offer a direct private-agent start action; the interface must not imply unsupported ownership.
- The Talk to surface always appears as `@doc`. A provider picker may select an advanced engine behind it, but switching engines must not change the product name, group affordance, or sharing language.
- Long-pressing a group message offers **Send to `@doc`** and stages only the selected message plus its visible sender label for editing and confirmation; it never auto-sends. Outputs always offer **Share** to a Convo or any installed chat app, and document-like outputs carry the Made by Convos invitation.
- The group-agent model picker offers ChatGPT, Claude, Grok, Gemini, and DeepSeek as the current prototype catalog.
- Any doc, sheet, calendar plan, link, file, or saved context item may be used anywhere. The explicit Share flow puts the native iOS share sheet above the in-app Convos destinations so the real underlying URL or file can go to any installed chat app. Choosing a Convo stages the item in its composer for review and never auto-sends it. Document-like shares include the Made by Convos invitation exactly once.

## Capabilities and Constraints

- Preserve Convos' invitation-only, identity-per-conversation, local-first privacy model.
- Treat connected-agent provider metadata as absent unless the profile's visibility flag is explicitly true. Turning visibility off removes the provider list while preserving unrelated profile metadata. Device-local consent and the remembered-provider roster are keyed by active inbox, never installation-wide; Delete All clears both plus personal-agent credentials before a new inbox can use the device.
- Use the existing conversation store and navigation paths; the prototype must not fabricate real messages or imply that private context has been uploaded.
- Voice transcription and imported files stay on-device. Built-in `@doc` answers remain local and use the currently visible briefing data; when the user selects a connected advanced engine, the app sends the request and only the explicitly enabled, bounded Your Space snapshot to it.
- The home experience needs useful loading and empty-document states without reintroducing dashboard content.
- The conversation switcher must support many conversations, unread state, search, and direct navigation.
- The context library must support search, type filters, provenance, local notes/photos/voice/files, an editable personal card with bounded custom title-and-info fields, and an explicit add menu for context or connections.
- The first production-grade context index is deliberately bounded to the 500 newest combined results across at most 500 loaded conversations. It indexes supported attachments/link previews plus addresses, phone numbers, and emails detected within the latest 5,000 eligible text messages, capped at 250 useful-detail results. Broader semantic extraction and paging remain separate data-contract decisions.
- Visible context cards render the richest safe preview available: decrypted or local thumbnails, document thumbnails, text excerpts, map snapshots, and cached link artwork. A visible link card may hydrate metadata and artwork through the app's existing bounded rich-link service, then caches the result; background indexing never crawls preview hosts.
- External chat history is not presented as continuously mirrored. Cross-app context enters only through an explicit share/import or a future connection with visible provenance and retention controls; Use anywhere sends context outward through the native share sheet without weakening that boundary.
- Recent convo previews remain neutral context until the user explicitly saves one. The app must not present them as inferred personal facts without a dedicated suggestion contract.
- The initial prototype may use clearly isolated sample insight content in previews. Production summaries, provenance, ranking, and persistence remain an open data-contract decision.
- Existing notification, deep-link, QR joining, new-conversation, settings, stale-device, and conversation-detail behavior must remain reachable.

## Brand Commitments

- Product name: Convos.
- Voice: direct, human, bold, playful, private, and useful. Say `@doc`, docs, sheets, calendars, groups, and things people can do; bury “agent,” “model,” and “AI” unless the user opens advanced setup.
- The supplied “Switching Spaces” screenshot is a structural reference for a private landing space and title-bar switcher, not an instruction to copy its visual styling or its “Spaces” terminology.

## Evidence on Hand

- Current iOS application and design tokens in this repository.
- User-supplied concept screenshot at `/var/folders/3n/rwbv43pn3sj51ml6bhqrpl6r0000gn/T/codex-clipboard-3cc6e300-c7b1-40a2-9069-6480c38da797.png`.
- No confirmed production API currently provides cross-conversation summaries, attention ranking, or shareable personal-memory objects; the interface must label preview-only sample data and keep the integration boundary explicit.

## Product Principles

1. One-line understandable: Turn anything into a group doc.
2. Useful before signup: a shared doc stands on its own and carries the invitation back to the group.
3. Intelligence stays underneath: people use docs, sheets, and calendars rather than managing AI infrastructure.
4. Private by default: listening, connections, permissions, and personal context are explicit and inspectable.
5. Show provenance: every update names its group and source so the user can trust and inspect it.

## Accessibility & Inclusion

- Preserve Dynamic Type, VoiceOver labels and ordering, minimum 44-point controls, sufficient contrast, Reduce Motion behavior, and non-color indicators for unread and urgency states.
- Summaries must not require familiarity with a person's display name alone; conversation provenance and explicit action labels remain available to assistive technology.
