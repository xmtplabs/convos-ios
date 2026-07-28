# Convos Design System

The Convos design system turns the app's existing visual language into a small,
repeatable framework. It does not introduce a new brand direction. The current
app remains the source of truth.

## Product principles

The interface should feel:

- **Private**: calm, direct, and free of attention-seeking chrome.
- **Human**: conversational language, generous spacing, and soft geometry.
- **Impermanent**: lightweight surfaces that do not feel like permanent records.
- **Self-evident**: actions explain themselves without requiring product knowledge.
- **Native**: Dynamic Type, VoiceOver, system controls, and platform behavior come first.

## Architecture

The system has four layers:

1. **Foundations** in
   `ConvosCore/Sources/ConvosComposer/DesignConstants.swift`: spacing, radii,
   typography, layout metrics, opacity, motion, and image sizes shared with the
   message composer.
2. **Semantic color assets** in `Convos/Assets.xcassets`: color names describe
   their role instead of a literal value and include light/dark appearances.
3. **Styles** in `Convos/Design System/Styles`: typography, surfaces, and buttons.
4. **Components** in `Convos/Design System/Components`: reusable interface
   patterns built only from foundations and styles.

The catalog in `Convos/Design System/DesignSystemCatalogView.swift` is the
visual inventory. Its light and dark previews should be reviewed whenever a
foundation or shared component changes.

Development builds also expose the catalog from **Settings -> Debug -> Features
-> Design system catalog**, which makes it available in Firebase builds without
Xcode.

The baseline inventory and migration priorities are documented in
[`design-system-audit.md`](./design-system-audit.md).

## Foundations

### Spacing

Use the existing four-point scale under `DesignConstants.Spacing`.

| Token | Value | Typical use |
| --- | ---: | --- |
| `stepHalf` | 2 | Tight text pairs |
| `stepX` | 4 | Badge and inline detail |
| `step2x` | 8 | Related controls |
| `step3x` | 12 | Row content |
| `step4x` | 16 | Component padding |
| `step6x` | 24 | Sections and screen margins |
| `step10x` | 40 | Sheets and large separation |

Use a raw number only when it represents content geometry rather than layout,
such as a generated QR code size.

### Typography

Apply `convosTextStyle(_:)` to app text:

| Role | Use |
| --- | --- |
| `.display` | Branded screen and sheet titles |
| `.title` | Page and major section titles |
| `.headline` | Section and card headings |
| `.body` | Primary content |
| `.bodySecondary` | Full-size explanatory and error copy |
| `.callout` | Compact empty-state and inline guidance |
| `.supportingPrimary` | Secondary-size text that still needs primary emphasis |
| `.supporting` | Explanations, metadata, and secondary content |
| `.detail` | Small explanatory copy |
| `.label` | Badges and compact controls |
| `.caption` | Timestamps and quiet detail |

Prefer these roles to fixed point sizes. `TightLineHeightText` remains available
for the few branded 40-point sheet titles that require exact line-height control.

### Color

Use semantic assets rather than system colors or RGB values:

- Backgrounds: `colorBackgroundSurfaceless`, `colorBackgroundRaised`,
  `colorBackgroundRaisedSecondary`, `colorBackgroundInverted`
- Text: `colorTextPrimary`, `colorTextSecondary`, `colorTextTertiary`,
  `colorTextPrimaryInverted`
- Fills: `colorFillPrimary`, `colorFillMinimal`, `colorFillSubtle`
- Borders: `colorBorderSubtle`, `colorBorderSubtle2`
- Feedback: `colorWarning`, `colorCaution`

Do not add a new color asset until an existing semantic role has been ruled out
in both light and dark mode.

### Layout and interaction

`DesignConstants.Layout` contains shared geometry:

- Minimum tap target: 44 points
- Icon tile: 40 points
- Search field: 48 points
- Screen horizontal inset: 24 points
- Sheet horizontal inset: 40 points
- Readable content width: 680 points

Pressed, disabled, and subdued states come from `DesignConstants.Opacity`.
Animation durations come from `DesignConstants.Motion` and must respect Reduce
Motion when movement communicates more than a simple state transition.

## Shared styles and components

| API | Purpose |
| --- | --- |
| `convosTextStyle(_:)` | Semantic font and foreground color |
| `convosSurface(_:padding:)` | Background, radius, and optional border |
| `convosButtonStyle(_:)` | Primary, secondary, text, capsule, and action buttons |
| `ConvosBadge` | Neutral, subtle, accent, warning, and danger labels |
| `ConvosIconTile` | Standard symbol tile used by settings and action rows |
| `ConvosSettingsRow` | Icon, title, optional subtitle, and caller-supplied accessory |
| `ConvosEmptyStateCard` | Compact empty state with one recovery action |
| `FeatureInfoSheet` | Full explanatory sheet with primary and optional secondary actions |

Components own appearance and layout. Feature views own copy, state, navigation,
and business behavior.

## Accessibility

Every shared component should:

- Support Dynamic Type without clipping essential text.
- Keep interactive targets at least 44 by 44 points.
- Use semantic colors that work in light and dark mode.
- Preserve a useful VoiceOver reading order.
- Add a spoken label when appearance alone communicates state.
- Avoid relying on color as the only status indicator.
- Respect Reduce Motion for decorative or spatial animation.

Review the catalog at large accessibility text sizes in light and dark mode.

## Adoption

Migrate incrementally when a screen is already being changed:

1. Replace raw layout values with an existing foundation token.
2. Replace direct font/color pairs with `convosTextStyle(_:)`.
3. Replace repeated surface styling with `convosSurface(_:padding:)`.
4. Reuse a shared component when structure and behavior match.
5. Add or update a preview for every new component state.

Do not rewrite stable screens solely to reach complete design-system adoption.
Repeated patterns should become components only after their shared shape is clear.

## Review checklist

- Uses semantic colors and typography roles
- Uses spacing, radius, and layout tokens where applicable
- Covers loading, empty, error, disabled, and pressed states
- Works in light and dark mode
- Works with large Dynamic Type and VoiceOver
- Preserves a minimum 44-point tap target
- Includes previews for shared components
- Does not move feature state or business logic into the design system
