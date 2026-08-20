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

**Creative North Star: "The Private Signal Desk"**

Convos is a quiet personal briefing room, not an inbox dashboard. Its visual world is restrained and editorial: open space, adaptive neutral surfaces, circular identity, a bounded recent-Convos list, and one expressive personal-library card.

The briefing voice is expressive, while every control around it remains unmistakably native iOS. System components, semantic colors, Dynamic Type, and familiar sheet and list behavior keep the interface calm and trustworthy; privacy is communicated through visible provenance and deliberate boundaries rather than decorative security theater.

The authenticated shell evolves `YS-SHELL-2026-08-18`: profile at top left opens Me & My Stuff, the centered space switcher remains anchored, add sits at top right, and a More–agent command–chat tray remains at the bottom. Settings is nested inside Me & My Stuff. The switcher expands downward from the header rather than rising from the bottom.

**Key Characteristics:**

- Restrained, adaptive Convos neutrals with Lava reserved for unread state and the live voice entry point.
- One editorial serif briefing voice inside an otherwise system-sans interface.
- Circular identity, native capsules, and one softly rounded attention surface.
- System glass only on persistent shell controls; native sheets and lists everywhere else.
- Private-by-default content with explicit, user-initiated sharing from a conversation composer.

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

**The Signal and Voice Rule.** Lava is limited to compact unread signals and the waveform well inside the agent command bar; green remains a compact confirmation signal. Neither becomes decorative surface paint.

## Typography

**Display Font:** SwiftUI system serif design with Dynamic Type
**Body Font:** SF system sans with Dynamic Type

**Character:** The system serif makes the live briefing feel considered and personal. SF system sans carries every title, row, label, control, sheet, and supporting sentence so the product stays familiar and legible.

### Hierarchy

- **Briefing** (bold, `largeTitle`, tracked `-0.6pt`): The launch sentence only; it expands vertically without a line limit.
- **Section Title** (bold, `title2`): Major briefing groups such as recent updates, people, and footprint.
- **Headline** (system headline, usually semibold): Attention labels, row leads, privacy promises, and accessible actions.
- **Body** (system body): Message previews, provenance, descriptions, controls, and explanatory copy.
- **Supporting Label** (system subheadline or caption): Conversation destinations, relative time, counts, and compact identity labels.

**The One Serif Sentence Rule.** Reserve the system serif for the main briefing sentence; controls, rows, widgets, and sheet content remain SF system sans.

## Layout

The shell is based on `YS-SHELL-2026-08-18`. Its top safe-area bar places circular profile identity, a flexible centered switcher, and a circular add control on one line. Settings lives inside Me & My Stuff so the home chrome stays focused. The main briefing scrolls independently beneath it, and a fixed More–agent command–chat tray occupies the bottom safe area when reading size permits. The flexible command bar names its purpose in text instead of relying on an isolated waveform symbol.

The home scroll view owns the visible viewport. Temporary chrome such as the anchored convo switcher is an overlay on that viewport and must never wrap, expand, or replace the scroll container's layout bounds. Its reading order begins with Recent Convos and the high-frequency personal destinations; the serif private briefing closes the scroll, directly after Your Space footprint when present, as supporting context rather than launch-page hero copy.

Content follows the existing `DesignConstants.Spacing` four-point rhythm. The main column uses a `24pt` horizontal inset, `32pt` top inset, `40pt` section rhythm, and `64pt` bottom breathing room, with a maximum readable width of `720pt`. Full-width empty-state and accessibility actions stop at `520pt`.

At accessibility Dynamic Type sizes, the bottom controls leave the safe-area overlay and reappear as full-width, `52pt`-minimum actions inside the scrolling content. The compact top chrome caps at the largest standard Dynamic Type size so profile, switcher, and add remain one usable row while the briefing continues to scale through the accessibility sizes. Text wraps vertically, update details retain conversation provenance, and controls preserve at least a `44pt` target without squeezing the briefing.

**The Pinned Shell Rule.** Preserve the profile–switcher–add top line and More–agent command–chat bottom line. Keep settings inside the profile section. The complete conversation index belongs in the anchored searchable panel; Home may show exactly three recent shortcuts, never an unbounded replacement inbox.

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

- **Profile:** A circular `40pt` avatar inside a `44pt` target with a subtle semantic border; it opens Me & My Stuff and does not use glass.
- **Switcher:** A flexible `44pt`-minimum capsule with a semibold body label and secondary chevron. It opens a right-aligned panel directly below the header, approximately 74% of the available content height. The panel keeps Your Space first, then search, then the complete recency-sorted convo list with unread state in `68pt`-minimum rows.
- **Settings:** A gear inside Me & My Stuff opens the existing app settings surface without adding another Home control.
- **Add:** A circular interactive-glass control exposing exactly start and QR-join actions.
- **More:** A circular interactive-glass `Menu` whose native popup opens Bring your own agent, Connections, Upload files, Files, Add a widget, and Connected convos directly—without an intermediate tools sheet.
- **Voice:** A centered `56pt` Lava circle with a waveform symbol; it opens on-device recording and transcription into the private briefing assistant.
- **Chat:** A trailing `44pt` interactive-glass circle with a filled message symbol; it opens the private text input surface.

### Briefing Voice

The large system-serif sentence is the signature component. It describes what needs attention, or explicitly says nothing does, and follows with a system-body source summary so every claim remains attributable to connected convos.

### Recent Convos

Exactly the three most recent real conversations appear under the narrative when at least three exist. Rows stay flat on the canvas, use `48pt` circular avatars inside `72pt`-minimum targets, one-line previews, native dividers, explicit unread language, and a small Lava signal. Tapping pushes directly into the full-height Group surface; no Desktop or group-home screen sits between Home and chat.

### Convo Surface Switcher

Every Convo is one full-screen shell with a fixed, equal-width **Desktop / Group / Agent** switcher at the bottom. Regular Convo entry always selects Group. Desktop and Group share the top group chrome: a `44pt` Back control at left, the group identity/settings control centered, and Invite at right. Agent is the private lane and keeps only Back. The shell never exposes a half-height chat state or a resize grabber. Switching surfaces preserves the Desktop browser stack, transcript positions, and composer drafts.

### Me & My Stuff

Home carries one generous navigational summary card with profile identity, counts for photos, links, files, and connections, a useful-details count, and a View all affordance. It never opens directly into edit mode. Its pushed destination begins with the personal card, followed by search, the category grid, compact Useful details filters, recent assets, and See all context. A distinct Edit toolbar action opens the contact-card editor, including bounded remembered fields and neutral recent-context suggestions. Every item preserves source-convo and sender provenance when available; private local items are labeled as such.

Agents across your convos uses native rows with agent identity, source convo, and a direct private-lane affordance. It renders three rows initially and See all expands the existing bounded list inline.

Bring personal agents to Convos is a permanent raised-neutral section immediately after Me. Its boundary copy states that the lane belongs only to the user, is not connected to a group, and cannot be messaged by group members. The same connection flow is reachable from More. Codex uses Mac pairing and a revocable capability token; Town uses its MCP connection; Tasklet appears directly below Town and combines the one-use MCP return bridge with a Tasklet webhook automation. Grok Bot appears directly below Tasklet and uses one outbound-only computer session: its waiting state exposes a clearly labeled Copy pairing token action with password-level handling guidance, its native multi-select list turns each enabled machine agent into a separately named `Grok Bot · Name` harness, and Check for new Grokbots lets the user add more later. Sensitive connection fields stay in Keychain. The persistent command bar names the active harness and offers a native switcher. Added provider identities persist independently of credentials; a disconnected row routes into provider-specific reconnect. Agent results render returned web links as explicit actions; the whole result or an individual link may be saved privately and staged for sharing. Talk to always starts with and defaults to the single group-local Convos agent—the verified live lane when available, or its orange fallback while syncing—then lists external agents the user has added, every enabled Grok Bot harness, and Ghost. Claude Code, Hermes, and OpenClaw remain previews; Connect MCP is Coming soon.

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

Voice transcription, grounded chat answers, imported files, personal-card notes, and saved personal-agent text outputs remain on-device in Your Space. Any library item may expose an explicit Share action. Sharing first asks for a destination convo, then opens that convo with the item staged in its composer for review; it never sends automatically. The existing group-composer Share context flow remains available in PR and Dev prototype builds and is not yet enabled in Production.

**The Open Boundary Rule.** Private context may cross into a convo only after the user explicitly chooses both the item and destination, and the destination composer visibly stages it for review. Creating, editing, browsing, or searching home context remains private.

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
