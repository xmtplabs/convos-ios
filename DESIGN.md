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
  sheet-primary-action:
    backgroundColor: "{colors.attention-surface}"
    textColor: "{colors.text-on-attention}"
    typography: "{typography.headline}"
    height: "52pt"
---

# Design System: Convos

## Overview

**Creative North Star: "The Private Signal Desk"**

Convos is a quiet personal briefing room, not an inbox dashboard. Its visual world is restrained and editorial: open space, adaptive neutral surfaces, circular identity, and a single decisive inverted surface that tells the user where attention is useful.

The briefing voice is expressive, while every control around it remains unmistakably native iOS. System components, semantic colors, Dynamic Type, and familiar sheet and list behavior keep the interface calm and trustworthy; privacy is communicated through visible provenance and deliberate boundaries rather than decorative security theater.

The authenticated shell follows the pinned topology `YS-SHELL-2026-08-18`: profile at top left, the centered space switcher, add at top right, private content between them, and a More–voice–chat dock at the bottom. The topology is durable; the content within the private space can grow as the product's evidence improves.

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
- **Voice Lava** (`voice-action`): The compact centered voice action; it is the only persistent solid accent control.
- **Included Green** (`included-signal`): A compact confirmation marker in the connected-conversations list.

### Neutral

- **Surfaceless Canvas** (`canvas`): The edge-to-edge app background and quiet base behind briefing content.
- **Raised Neutral** (`raised-neutral`): Tonal separation for compact secondary containers such as the footprint widget and sheet backgrounds.
- **Primary, Secondary, and Tertiary Text** (`text-primary`, `text-secondary`, `text-tertiary`): The semantic hierarchy for content, supporting context, and de-emphasized indicators.
- **Attention Text and Fill** (`text-on-attention`, `fill-on-attention-subtle`): The paired inverted roles used inside the attention surface.
- **Subtle Border** (`border-subtle`): A low-contrast edge for circular profile identity; dividers otherwise remain native.

**The Semantic Neutral Rule.** Always use the adaptive Convos asset role for a surface or text hierarchy; do not replace it with a fixed light-appearance value.

**The Inverted Attention Rule.** Give the briefing at most one solid inverted attention surface at a time so its rarity continues to mean “start here.”

**The Signal and Voice Rule.** Lava is limited to compact unread signals and the centered voice action; green remains a compact confirmation signal. Neither becomes decorative surface paint.

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

The shell is pinned to `YS-SHELL-2026-08-18`. Its top safe-area bar places circular profile identity, a flexible centered switcher, and a circular add menu on one line. The main briefing scrolls independently beneath it, and a fixed three-position More–voice–chat dock occupies the bottom safe area when reading size permits. Equal side regions keep the `56pt` voice action physically centered between `44pt` side controls.

Content follows the existing `DesignConstants.Spacing` four-point rhythm. The main column uses a `24pt` horizontal inset, `32pt` top inset, `40pt` section rhythm, and `64pt` bottom breathing room, with a maximum readable width of `720pt`. Full-width empty-state and accessibility actions stop at `520pt`.

At accessibility Dynamic Type sizes, the bottom controls leave the safe-area overlay and reappear as full-width, `52pt`-minimum actions inside the scrolling content. The compact top chrome caps at the largest standard Dynamic Type size so profile, switcher, and add remain one usable row while the briefing continues to scale through the accessibility sizes. Text wraps vertically, update details retain conversation provenance, and controls preserve at least a `44pt` target without squeezing the briefing.

**The Pinned Shell Rule.** Preserve the profile–switcher–add top line and More–voice–chat bottom line; conversations belong behind the switcher, not in a large home-screen list.

**The Accessibility Reflow Rule.** When text reaches an accessibility size, move persistent bottom actions into the content flow rather than forcing them to compete with enlarged text.

## Elevation & Depth

The system has no custom shadow vocabulary. Depth comes from semantic tonal layers, native bars, native sheets, and iOS system glass. Glass is reserved for neutral persistent shell controls—the centered switcher, add, More, and chat controls—using the platform's interactive regular treatment rather than hand-built blur or translucent cards. Voice is the one solid Lava control.

**The Native Depth Rule.** Use system materials for persistent chrome and system sheet presentation for modal depth; content surfaces stay flat unless a semantic tonal or inverted layer carries meaning.

## Shapes

Identity is circular: profile and conversation avatars, people, unread dots, and compact icon wells all use circles. Persistent actions use native circle or capsule geometry. The attention action and compact footprint container use the established medium corner (`16pt`); native lists and sheets retain their platform-provided form rather than becoming a bespoke card stack.

**The Circular Identity Rule.** People, convos, and compact shell actions stay circular; rounded rectangles are reserved for information surfaces and full-width actions.

## Components

### Persistent Shell Controls

- **Profile:** A circular `40pt` avatar inside a `44pt` target with a subtle semantic border; it opens settings and does not use glass.
- **Switcher:** A flexible `44pt`-minimum capsule with a semibold body label and secondary chevron; it opens the searchable conversation switcher.
- **Add:** A circular interactive-glass control exposing exactly start and QR-join actions.
- **More:** A circular interactive-glass `Menu` whose native popup opens Connections, Upload files, Files, Add a widget, and Connected convos directly—without an intermediate tools sheet.
- **Voice:** A centered `56pt` Lava circle with a waveform symbol; it opens on-device recording and transcription into the private briefing assistant.
- **Chat:** A trailing `44pt` interactive-glass circle with a filled message symbol; it opens the private text input surface.

### Briefing Voice

The large system-serif sentence is the signature component. It describes what needs attention, or explicitly says nothing does, and follows with a system-body source summary so every claim remains attributable to connected convos.

### Attention Action

One full-width inverted surface uses the medium corner, a `44pt` circular icon well, a headline, and a one-line destination. The complete surface is one button and opens the first conversation requiring attention.

### Update Rows

Rows remain flat on the canvas and use a circular `44pt` conversation avatar, headline, body preview, provenance, relative time, and an optional `8pt` Lava dot. Native dividers begin after the avatar column. VoiceOver combines the row and expresses attention in words rather than relying on the dot.

### People and Footprint

People are presented as horizontally scrolling `52pt` circular identities with compact labels. The optional footprint is a raised neutral container split by native dividers into equal numeric columns; numbers use monospaced digits while labels remain captions.

### Native Sheets and Lists

The switcher, More menu destinations, sources, stored files, widget controls, and private input surfaces use `NavigationStack`, inset-grouped `List`, native `Menu`, native file importer, search, toggles, toolbar actions, presentation detents, and drag indicators.

### Private Input and Share Boundary

Voice transcription, grounded chat answers, and imported files remain on-device in Your Space. The home screen has no Share context action. In PR and Dev prototype builds, personal context can enter a group only through the separate, explicit Share context choice in that group's composer; that composer action is not yet enabled in Production, and nothing on the home surface sends automatically.

**The Open Boundary Rule.** Private context may cross into a convo only through an explicit composer action in that destination; home voice, chat, and file actions remain private.

## Do's and Don'ts

### Do:

- **Do** compose new surfaces from Convos semantic asset colors so Light Mode and Dark Mode invert together.
- **Do** use Dynamic Type text styles and allow the briefing, descriptions, and provenance to wrap.
- **Do** keep identity circular and every interactive target at least `44pt`.
- **Do** use native navigation, sheets, lists, search, toggles, menus, and SF Symbols.
- **Do** name the source convo and express unread or urgency with words as well as color.
- **Do** preserve the pinned `YS-SHELL-2026-08-18` topology and its private-by-default composer boundary.

### Don't:

- **Don't** use the serif voice for controls, row content, settings, or sheet titles.
- **Don't** scatter inverted cards, bright accents, glass content cards, gradients, or custom shadows through the briefing.
- **Don't** hand-build glass, modal chrome, list rows, search fields, or platform transitions.
- **Don't** turn the home into a large conversation list or add a permanent contacts destination to this shell.
- **Don't** infer a person's identity from message text, imply server-side synthesis, or suggest that home context was uploaded or sent automatically.
- **Don't** keep bottom overlay actions in place when accessibility Dynamic Type makes them compete with content.
