# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People who participate in several private Convos and want to understand what changed, who needs attention, and what matters without opening every conversation one by one.

## Product Purpose

Convos is an everyday private messenger for the surveillance age. This prototype makes the app's default destination a private personal space that connects context across a person's conversations, surfaces meaningful updates, and helps them decide where to act next.

Success means opening Convos immediately answers “what is new and what deserves my attention?” while keeping every underlying conversation easy to reach.

## Positioning

The home screen is not an inbox. It is a private, continuously growing layer of personal context assembled from the user's Convos. It can help the user remember people, notice changes across groups, and selectively bring personal context back into a specific conversation without making that context public by default.

## Operating Context

- The user lands in “Your Space” every time they open the app.
- The title control at the top opens every conversation as a switcher rather than reserving the home screen for a large chat list.
- A top-right add control starts a new conversation or joins one by scanning a QR code.
- The profile image at top left opens app settings.
- A native overflow menu exposes connections, private file upload, stored files, home customization, and the conversations contributing to the private space.
- The bottom dock keeps voice as the centered primary action and chat as the secondary action on the right.
- Contacts are selected in the invite flow for a conversation rather than occupying a permanent bottom-level destination.
- Personal context may be shared into a conversation only through an explicit user action.

## Capabilities and Constraints

- Preserve Convos' invitation-only, identity-per-conversation, local-first privacy model.
- Use the existing conversation store and navigation paths; the prototype must not fabricate real messages or imply that private context has been uploaded.
- Voice transcription, chat answers, and imported files stay on-device in this prototype; chat answers are grounded only in the currently visible briefing data.
- The home experience needs useful loading, empty, unread, and no-attention states.
- The conversation switcher must support many conversations, unread state, search, and direct navigation.
- The initial prototype may use clearly isolated sample insight content in previews. Production summaries, provenance, ranking, and persistence remain an open data-contract decision.
- Existing notification, deep-link, QR joining, new-conversation, settings, stale-device, and conversation-detail behavior must remain reachable.

## Brand Commitments

- Product name: Convos.
- Voice: direct, human, calm, private, and useful; never surveillance-like or breathlessly “AI.”
- The supplied “Switching Spaces” screenshot is a structural reference for a private landing space and title-bar switcher, not an instruction to copy its visual styling or its “Spaces” terminology.

## Evidence on Hand

- Current iOS application and design tokens in this repository.
- User-supplied concept screenshot at `/var/folders/3n/rwbv43pn3sj51ml6bhqrpl6r0000gn/T/codex-clipboard-3cc6e300-c7b1-40a2-9069-6480c38da797.png`.
- No confirmed production API currently provides cross-conversation summaries, attention ranking, or shareable personal-memory objects; the interface must label preview-only sample data and keep the integration boundary explicit.

## Product Principles

1. Private by default: Your Space belongs to one person, and sharing out is deliberate.
2. Orient before opening: the first screen explains what changed and where attention is valuable.
3. Conversations stay one gesture away: replacing the inbox must not make navigation slower.
4. Context compounds: the surface should become more useful as relationships and conversations grow.
5. Show provenance: every update names its conversation, and names a person only when verified sender metadata is available, so the user can trust and inspect it.

## Accessibility & Inclusion

- Preserve Dynamic Type, VoiceOver labels and ordering, minimum 44-point controls, sufficient contrast, Reduce Motion behavior, and non-color indicators for unread and urgency states.
- Summaries must not require familiarity with a person's display name alone; conversation provenance and explicit action labels remain available to assistive technology.
