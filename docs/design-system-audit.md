# Convos UI Audit

> Audited: 2026-07-27
> Scope: main `Convos` app target and the shared `ConvosComposer` UI

## Inventory

The app currently contains:

- 239 Swift files in the main app target
- 145 SwiftUI previews
- 50 semantic color assets
- 534 uses of the shared spacing scale across 87 files
- 49 uses of shared corner-radius tokens
- 52 uses of `convosButtonStyle(_:)` across 22 files
- 297 numeric padding or corner-radius expressions
- 27 fixed-size system-font expressions

Numeric values are not automatically defects. Avatar sizes, QR geometry, media
frames, and animation coordinates often need explicit dimensions. The count is a
map of places to review when nearby feature work changes a surface.

## Screen families reviewed

### Conversations

The conversations list combines UIKit collection-view cells with SwiftUI empty,
pinned, filter, and agent-builder surfaces. Its strongest reusable patterns are
avatar rendering, semantic text colors, spacing tokens, and button styles.

The main opportunity is to standardize empty states, card surfaces, and screen
insets while preserving the list's performance-sensitive UIKit implementation.

### Conversation detail and composer

This is the deepest component family and already shares many primitives through
`ConvosComposer`: messages, reactions, attachments, indicators, reply references,
agent state, avatars, and composer controls.

The composer package is the correct owner for foundations used by both UIKit and
SwiftUI message surfaces. App-only navigation and sheets should remain outside
the package.

### Contacts and people

Contact browse, picker, and detail surfaces intentionally share avatars, row
geometry, and identity badges. They are a strong candidate for shared row,
badge, and icon-tile components because the product already treats these as one
family in multiple modes.

### Conversation creation and invites

Creation, joining, QR, and sharing surfaces use the same generous sheet spacing,
rounded cards, and high-contrast primary actions. The existing
`FeatureInfoSheet` and QR components should remain the composition anchors.

### Settings, devices, and subscriptions

These surfaces repeatedly use a 40-point icon tile, title/subtitle stacks,
trailing controls, raised backgrounds, and large branded titles. The first
framework migration extracts that row pattern as `ConvosSettingsRow`.

Subscription screens intentionally have richer card geometry and should consume
foundations without being flattened into generic settings components.

### Agents and capabilities

Agent builder, connection, and capability surfaces share status labels, icon
tiles, explanatory copy, and primary/secondary actions. Semantic badge tones and
standard surfaces reduce one-off status treatments without hiding feature state.

## Existing strengths

- Colors are already semantic and light/dark aware.
- The four-point spacing scale is widely adopted.
- The app has unusually strong preview coverage.
- Shared composer UI has a clear package home.
- Buttons already expose a small semantic API.
- Feature plans frequently call out component reuse and mode-based composition.

## Main consistency gaps

### Typography is expressed as implementation

Most views combine a direct SwiftUI font with a semantic text color. A named
role such as `body` or `supporting` better captures intent and lets type ramp
changes happen centrally.

### Surfaces are rebuilt locally

Cards and raised areas often repeat background, radius, border, padding, and
clip-shape modifiers. A semantic surface modifier keeps those decisions together.

### Repeated row anatomy has no shared owner

Several settings and permission surfaces repeat icon tile, text stack, spacer,
and trailing accessory layout. This is now represented by `ConvosSettingsRow`.

### Status labels drift

Role, blocked, pending, and warning labels use similar capsules with subtly
different font, padding, fill, and capitalization. `ConvosBadge` provides a
shared base with semantic tones.

### Raw values mix layout and content geometry

Some numeric values are meaningful content dimensions; others duplicate spacing,
tap target, icon tile, or inset decisions. `DesignConstants.Layout` names the
high-frequency shared geometry so future reviews can distinguish them.

## Framework introduced

- Shared layout, image-size, opacity, motion, and typography foundations
- Semantic `convosTextStyle(_:)`
- Semantic `convosSurface(_:padding:)`
- Token-backed button interaction states
- `ConvosBadge`
- `ConvosIconTile`
- `ConvosSettingsRow`
- `ConvosEmptyStateCard`
- Light and dark design-system catalog
- Development-build debug route for reviewing the catalog on Firebase devices

Representative migrations cover settings, contacts, role labels, filtered empty
states, and informational sheets.

## Migration order

### Adopt during normal feature work

1. Typography roles and standard screen/sheet insets
2. Status badges and repeated icon tiles
3. Settings, permission, and connection rows
4. Empty, loading, and error states
5. Repeated card and raised-surface treatments

### Preserve specialized components

- Message bubbles and transcript layout
- Composer controls
- QR rendering geometry
- Media and avatar crops
- Subscription tier selection
- Destructive hold and explode interactions

These components can use shared foundations without becoming generic.

### Add later when build tooling is available

- Preview snapshots for the catalog in light/dark and accessibility sizes
- A lint rule that flags new raw RGB colors and arbitrary layout values
- Accessibility UI checks for tap targets and clipped text
- A debug-only route to the catalog for device review, if the team wants it

## Success criteria

The system is working when:

- New screens start with semantic roles instead of copied modifier stacks.
- Existing screens can migrate locally without broad rewrites.
- Light/dark and accessibility behavior improve when a shared primitive changes.
- Designers and engineers use the same names for text, surfaces, spacing, and components.
- The app still feels recognizably Convos rather than like a generic component library.
