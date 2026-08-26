---
name: "Convos"
description: "A restrained private signal desk for understanding what changed across conversations."
colors:
  attention-surface: "light-dark(#000000, #ffffff)"
  canvas: "light-dark(#ffffff, #000000)"
  raised-neutral: "light-dark(#f5f5f5, #1c1c1c)"
  text-primary: "light-dark(#000000, #ffffff)"
  text-secondary: "light-dark(#666666, #999999)"
  text-tertiary: "light-dark(#b2b2b2, #4d4d4d)"
  text-on-attention: "light-dark(#ffffff, #000000)"
  fill-on-attention-subtle: "light-dark(#333333, #f5f5f5)"
  border-subtle: "light-dark(#ebebeb, #333333)"
  unread-signal: "#fc4f37"
  included-signal: "#34c759"
typography:
  briefing:
    fontFamily: "SF system serif, ui-serif, serif"
    fontSize: "largeTitle"
    fontWeight: 700
    letterSpacing: "-0.6pt"
  section-title:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "title2"
    fontWeight: 700
  headline:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "headline"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "body"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "caption"
    fontWeight: 400
rounded:
  medium: "16pt"
spacing:
  step-half: "2pt"
  step-x: "4pt"
  step-2x: "8pt"
  step-3x: "12pt"
  step-4x: "16pt"
  step-5x: "20pt"
  step-6x: "24pt"
  step-8x: "32pt"
  step-10x: "40pt"
  step-11x: "44pt"
  step-16x: "64pt"
components:
  shell-switcher:
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    padding: "0 20pt"
    height: "{spacing.step-11x}"
  convo-switcher-panel:
    backgroundColor: "{colors.raised-neutral}"
    textColor: "{colors.text-primary}"
    maxHeight: "74% of the content viewport, capped at 680pt"
    horizontalInset: "12pt"
  context-library-card:
    backgroundColor: "{colors.raised-neutral}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.medium}"
    padding: "{spacing.step-4x}"
  shell-icon-control:
    textColor: "{colors.text-primary}"
    size: "{spacing.step-11x}"
  attention-action:
    backgroundColor: "{colors.attention-surface}"
    textColor: "{colors.text-on-attention}"
    typography: "{typography.headline}"
    rounded: "{rounded.medium}"
    padding: "{spacing.step-4x}"
  update-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    padding: "16pt 0"
  footprint-widget:
    backgroundColor: "{colors.raised-neutral}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.medium}"
    padding: "16pt 0"
  people-identity:
    textColor: "{colors.text-secondary}"
    typography: "{typography.caption}"
    size: "52pt"
  sheet-selection-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
  agent-destination-sheet:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    minimumRowHeight: "{spacing.step-11x}"
  agent-handoff-receipt:
    backgroundColor: "transparent"
    textColor: "{colors.text-primary}"
    iconSize: "22pt"
    height: "36pt"
    borderColor: "{colors.border-subtle}"
  sheet-primary-action:
    backgroundColor: "{colors.attention-surface}"
    textColor: "{colors.text-on-attention}"
    typography: "{typography.headline}"
    height: "52pt"
---

# Design System: Convos

## Overview

**Creative North Star: "The Multiplayer Doc"**

Convos feels like a consumer social product that happens to make powerful work. The first screen is bold, immediate, and legible from across the room: one saturated Lava launch card, one enormous promise—**Add `@doc` to any group in your life**—and one black action. Everything after the launch card becomes quiet and useful: updated docs, recent groups, docs the user controls, and personal context.

The character is closer to Cash App than an enterprise AI dashboard: oversized rounded type, confident color, simple icon language, and blunt verbs. System components, semantic colors, Dynamic Type, and familiar sheets and lists keep the confidence usable and trustworthy.

The authenticated shell evolves `YS-SHELL-2026-08-18`: profile at top left opens Your context, the centered space switcher remains anchored, add sits at top right, and a More–agent command–chat tray remains at the bottom. Settings is nested inside Your context. The switcher expands downward from the header rather than rising from the bottom.

**Key Characteristics:**

- A saturated Convos Lava hero on Home with black type and a black primary action.
- Oversized rounded system typography for the product promise; sans typography everywhere.
- Circular identity, native capsules, and one softly rounded attention surface.
- System glass only on persistent shell controls; native sheets and lists everywhere else.
- Private-by-default content with explicit sharing and a branded invitation carried by every group doc.

## Colors

The palette is an adaptive black-to-white neutral system whose meaning survives Light Mode, Dark Mode, and increased contrast; the named values above mirror the existing semantic asset roles.

### Primary

- **Semantic Attention Ink** (`attention-surface`): The one high-emphasis surface for the next conversation that needs a look, paired only with its inverted text and subtle inverted fill roles.

### Tertiary

- **Unread Lava** (`unread-signal`): A tiny unread or attention marker; it supplements explicit language and never carries meaning alone.
- **Voice Lava** (`voice-action`): The compact waveform well inside the persistent agent command bar; it is the only persistent solid accent control.
- **Included Green** (`included-signal`): A compact confirmation marker in the connected-conversations list.

### Neutral

- **Surfaceless Canvas** (`canvas`): The edge-to-edge app background and quiet base behind briefing content.
- **Raised Neutral** (`raised-neutral`): Tonal separation for compact secondary containers such as the footprint widget and sheet backgrounds.
- **Primary, Secondary, and Tertiary Text** (`text-primary`, `text-secondary`, `text-tertiary`): The semantic hierarchy for content, supporting context, and de-emphasized indicators.
- **Attention Text and Fill** (`text-on-attention`, `fill-on-attention-subtle`): The paired inverted roles used inside the attention surface.
- **Subtle Border** (`border-subtle`): A low-contrast edge for circular profile identity; dividers otherwise remain native.

**The Semantic Neutral Rule.** Always use the adaptive Convos asset role for a surface or text hierarchy; do not replace it with a fixed light-appearance value.

**The Inverted Attention Rule.** Give the briefing at most one solid inverted attention surface at a time so its rarity continues to mean “start here.”

**The Launch Lava Rule.** Lava may fill exactly one dominant launch surface on Home and compact active controls elsewhere. Do not repeat large Lava cards lower in the hierarchy. Green remains a compact confirmation signal.

## Typography

**Display Font:** SwiftUI rounded system design with Dynamic Type
**Body Font:** SF system sans with Dynamic Type

**Character:** Rounded black display type makes the product promise friendly, iconic, and unmistakably consumer. SF system sans carries rows, controls, sheets, provenance, and supporting copy.

### Hierarchy

- **Product Promise** (black, rounded, `largeTitle` or larger, tracked `-0.8pt`): “Add `@doc` to any group in your life.” It expands vertically without a line limit.
- **Section Title** (bold, `title2`): Major briefing groups such as recent updates, people, and footprint.
- **Headline** (system headline, usually semibold): Attention labels, row leads, privacy promises, and accessible actions.
- **Body** (system body): Message previews, provenance, descriptions, controls, and explanatory copy.
- **Supporting Label** (system subheadline or caption): Conversation destinations, relative time, counts, and compact identity labels.

**The One Giant Promise Rule.** Home gets one giant rounded sentence. Controls, rows, widgets, and sheets remain SF system sans and do not compete with it.

## Layout

The shell is based on `YS-SHELL-2026-08-18`. Its top safe-area bar places circular profile identity, a flexible centered switcher, and a circular add control on one line. Settings lives inside Your context so the home chrome stays focused. The main briefing scrolls independently beneath it, and a fixed More–agent command–chat tray occupies the bottom safe area when reading size permits. The flexible command bar names its purpose in text instead of relying on an isolated waveform symbol.

The home scroll view owns the visible viewport. Temporary chrome such as the anchored convo switcher is an overlay on that viewport and must never wrap, expand, or replace the scroll container's layout bounds. Its reading order is `@doc` promise → docs updated → a mixed list of seven recent groups and `@doc` updates → Your `@docs` → All my things → optional supporting widgets. The conversation index remains one gesture away in the header rather than taking over Home.

Content follows the existing `DesignConstants.Spacing` four-point rhythm. The main column uses a `24pt` horizontal inset, `32pt` top inset, `40pt` section rhythm, and `64pt` bottom breathing room, with a maximum readable width of `720pt`. Full-width empty-state and accessibility actions stop at `520pt`.

At accessibility Dynamic Type sizes, the bottom controls leave the safe-area overlay and reappear as full-width, `52pt`-minimum actions inside the scrolling content. The compact top chrome caps at the largest standard Dynamic Type size so profile, switcher, and add remain one usable row while the briefing continues to scale through the accessibility sizes. Text wraps vertically, update details retain conversation provenance, and controls preserve at least a `44pt` target without squeezing the briefing.

**The Pinned Shell Rule.** Preserve the profile–switcher–add top line and More–agent command–chat bottom line. Keep settings inside the profile section. The complete conversation index belongs in the anchored searchable panel; Home may show at most seven recent Convo or agent shortcuts, never an unbounded replacement inbox.

**The Accessibility Reflow Rule.** When text reaches an accessibility size, move persistent bottom actions into the content flow rather than forcing them to compete with enlarged text.

**The Scroll Ownership Rule.** Overlay navigation on the bounded home viewport; never place the home scroll view inside a container that can adopt the scroll content's full height.

## Elevation & Depth

The system has no general custom shadow vocabulary. Depth comes from semantic tonal layers, native bars, native sheets, and iOS system glass. Glass is reserved for neutral persistent shell controls—the centered switcher, add, More, and chat controls—using the platform's interactive regular treatment rather than hand-built blur or translucent cards. Voice is the one solid Lava control. The anchored convo panel uses an opaque adaptive raised surface and one restrained shadow so underlying private content does not compete with navigation.

**The Native Depth Rule.** Use system materials for persistent chrome and system sheet presentation for modal depth; content surfaces stay flat unless a semantic tonal or inverted layer carries meaning.

## Shapes

Identity is circular: profile and conversation avatars, people, unread dots, and compact icon wells all use circles. Persistent actions use native circle or capsule geometry. The attention action and compact footprint container use the established medium corner (`16pt`); native lists and sheets retain their platform-provided form rather than becoming a bespoke card stack.

**The Circular Identity Rule.** People, convos, and compact shell actions stay circular; rounded rectangles are reserved for information surfaces and full-width actions.

## Components

### Persistent Shell Controls

- **Profile:** A circular `40pt` avatar inside a `44pt` target with a subtle semantic border; it opens Your context and does not use glass.
- **Switcher:** A flexible `44pt`-minimum capsule with a semibold body label and secondary chevron. It opens a right-aligned panel directly below the header, approximately 74% of the available content height. The panel keeps Your Space first, then search, then the complete recency-sorted convo list with unread state in `68pt`-minimum rows.
- **Settings:** A gear inside Your context opens the existing app settings surface without adding another Home control.
- **Add:** A circular interactive-glass control exposing exactly start and QR-join actions.
- **More:** A circular interactive-glass `Menu` whose native popup opens Bring your own agent, Connections, Upload files, Files, Add a widget, and Connected convos directly—without an intermediate tools sheet.
- **`@doc` command:** A centered flexible command bar with a Lava doc identity and “Make, edit, or find anything.” It opens voice or text input without exposing the selected engine.
- **Chat:** A trailing `44pt` interactive-glass circle with a filled message symbol; it opens the private text input surface.

### Product Promise

The saturated Home card is the signature component. It says “Add `@doc` to any group in your life,” explains that it makes and maintains docs, sheets, and calendars, and ends in one full-width black **Add `@doc`** action. Dynamic catch-up copy may appear beneath the action, but it never replaces or weakens the promise.

### Recent Groups and `@doc`

Up to seven real recency-sorted entries combine group conversations with `@doc` updates. Rows stay flat on the canvas, use circular identity inside `72pt`-minimum targets, one-line previews, native dividers, explicit unread language, and a small Lava signal. Group rows push directly into the full-height Group surface; `@doc` rows open its group workspace. A single See all action exposes the longer list.

### Convo Surface Switcher

Every Convo is one full-screen shell with a compact **Group / Agent / Context** control floating beneath the group identity. Regular Convo entry always selects Group. Back stays in the top-left `44pt` target; the centered identity opens group settings, and Invite remains at top right wherever group actions apply. Group is the normal conversation, Agent is the user's private lane with the group agent first and connected personal agents available from its selector, and Context is the group's Space. The shell never exposes a half-height chat state, resize grabber, or persistent bottom navigation. Group and Agent own their respective bottom composers, while Context devotes the viewport to the Space. Switching surfaces preserves the Context browser stack, transcript positions, selected personal agent, and composer drafts.

### Updated Things

Directly below the launch card, Home shows up to three recently updated documents, sheets, links, files, or notes with real previews or clear identity, source-group provenance, relative time, Open group, and Share. Tapping the content opens a preview whose first element is a compact Lava **Made by Convos** invitation. Every external share includes the phone number +1 309-555-5555 exactly once. This is the core loop: the group gets a useful thing, shares it anywhere, and the document teaches the next person to text `@doc` directly or add it to another group.

### All My Things

Home carries one generous **All my things** summary card with profile identity, counts for photos, links, files, and connections, a useful-details count, and a View all affordance. It never opens directly into edit mode. Its pushed destination begins with the personal card, followed by search, the category grid, compact Useful details filters, recent assets, and See all context. A distinct Edit toolbar action opens the contact-card editor, including bounded remembered fields and neutral recent-context suggestions. Every item preserves source-convo and sender provenance when available; private local items are labeled as such. Its final iMessage, WhatsApp, and Telegram actions route to agent setup rather than claiming external history is already mirrored.

Your `@docs` appears before All my things as one access-aware roster, clearly divided into **Docs you control** and **Docs shared with you**. Every doc detail begins with **Add `@doc` anywhere**: the published number, copy actions, iMessage/WhatsApp/Telegram instructions, and a Listen/Talk/Pause control. It then shows Connections and every group where that doc is available. Opening a group reveals permissions scoped to exactly that doc and group. Connected providers appear only under **Advanced engines**.

Advanced engines are deliberately buried behind `@doc` management. Connecting Codex, Town, Tasklet, Grok Bot, or another provider may change capability, but never changes the visible `@doc` identity or the group's mental model. Sensitive connection fields stay in Keychain; disconnected engines route into provider-specific reconnect.

### Social Agent Identity

A human profile may use the otherwise empty area below identity and actions for one compact native grouped section. When membership provenance shows that this person invited the verified group agent, the first row names that agent, says the person “set up” the agent for this convo, and offers a direct start action. A Connected agents group follows with circular provider badges, provider name and one-line description, native dividers, and disclosure indicators. Provider taps open the established connection directory focused on that provider; the final row invites the viewer to set up their own personal agents.

The current user's version places the native visibility toggle above the provider rows. The privacy promise sits beside a lock symbol in supporting text and names the boundary precisely: only provider names are shared. Other profiles repeat that boundary once below the group rather than on every row. This section uses the raised-neutral semantic surface, existing system type, `44pt` minimum targets, and no new gradient, decorative shadow, or competing accent.

Context-card preview wells show content rather than file-type glyphs: photos and videos use decrypted thumbnails, documents use Quick Look thumbnails, notes use excerpts, voice notes use a waveform and duration, addresses and map links use a map snapshot, and links use cached or safely hydrated rich-link artwork. Loading is scoped to visible cards and results are cached so the library remains responsive.

The `+` menu offers Add context and Add connections. Add context supports text notes, photos, voice notes, and native file import. Search or “See all context” opens a large, native-file-picker-like browser with type filters and an adaptive asset grid.

Recent message previews may be offered as neutral context for the user to review, but they are never labeled as inferred facts or suggestions about that person. Saving one to the personal card is always an explicit choice.

### Update Rows

Rows remain flat on the canvas and use a circular `44pt` conversation avatar, headline, body preview, provenance, relative time, and an optional `8pt` Lava dot. Native dividers begin after the avatar column. VoiceOver combines the row and expresses attention in words rather than relying on the dot.

### People and Footprint

People are presented as horizontally scrolling `52pt` circular identities with compact labels. The optional footprint is a raised neutral container split by native dividers into equal numeric columns; numbers use monospaced digits while labels remain captions.

### Native Sheets and Lists

Context browsing, More menu destinations, sources, stored files, widget controls, and private input surfaces use `NavigationStack`, inset-grouped `List`, native `Menu`, native file importer, search, toggles, toolbar actions, presentation detents, and drag indicators. The convo switcher is the intentional exception: it is an anchored top panel because its spatial relationship to the title control is part of the shell.

### Private Input and Share Boundary

Voice transcription, grounded chat answers, imported files, personal-card notes, and saved personal-agent text outputs remain on-device in Your Space. Any library item or agent may expose an explicit Share action. The first destination is **Any chat app**, which prepares the real file, URL, or text and invokes the native iOS share sheet; Convos destinations follow and stage the item in a composer for review. Neither path sends automatically. The existing group-composer Share context flow remains available in PR and Dev prototype builds and is not yet enabled in Production.

**The Open Boundary Rule.** Private context crosses an app boundary only after the user explicitly chooses the item and destination. Convos destinations visibly stage it for review; external destinations use the system share sheet. Creating, editing, browsing, or searching home context remains private.

## Do's and Don'ts

### Do:

- **Do** compose new surfaces from Convos semantic asset colors so Light Mode and Dark Mode invert together.
- **Do** use Dynamic Type text styles and allow the briefing, descriptions, and provenance to wrap.
- **Do** keep identity circular and every interactive target at least `44pt`.
- **Do** use native navigation, sheets, lists, search, toggles, menus, and SF Symbols.
- **Do** name the source convo and express unread or urgency with words as well as color.
- **Do** preserve the pinned `YS-SHELL-2026-08-18` topology, anchored convo panel, provenance, and private-by-default composer boundary.

### Don't:

- **Don't** use the serif voice for controls, row content, settings, or sheet titles.
- **Don't** scatter inverted cards, bright accents, glass content cards, gradients, or custom shadows through the briefing.
- **Don't** hand-build glass, modal chrome, list rows, search fields, or platform transitions.
- **Don't** grow the three-row recent section into a replacement inbox, present the switcher from the bottom, or add a permanent contacts destination to this shell.
- **Don't** infer a person's identity from message text, imply server-side synthesis, or suggest that home context was uploaded or sent automatically.
- **Don't** keep bottom overlay actions in place when accessibility Dynamic Type makes them compete with content.
