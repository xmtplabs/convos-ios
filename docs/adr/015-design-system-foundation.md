# ADR 015: Design System Foundation

> **Status**: Proposed
> **Author**: Convos team
> **Created**: 2026-07-27
> **Updated**: 2026-07-27

## Context

Convos already uses semantic color assets, a four-point spacing scale, shared
corner radii, button styles, and a small set of reusable views. Those pieces are
split between the main app and `ConvosComposer`, and many feature screens still
combine them with one-off font, spacing, surface, and interaction values.

The app needs a framework that makes the existing visual language easier to
reuse without forcing a broad rewrite or creating a second source of truth.

## Decision Drivers

- Maintain the current product character
- Improve consistency across independently developed features
- Keep shared composer UI visually aligned with the app
- Support light mode, dark mode, Dynamic Type, and VoiceOver by default
- Allow gradual adoption without blocking feature work
- Avoid a new package or third-party dependency until module boundaries require it

## Considered Options

### Keep informal conventions

Continue using existing assets and `DesignConstants` without a documented
component framework.

**Pros**:

- No migration cost
- Maximum local flexibility

**Cons**:

- Repeated patterns continue to drift
- Designers and engineers lack a shared vocabulary
- Accessibility behavior must be solved repeatedly

### Add a dedicated design-system Swift package

Move colors, tokens, styles, and components into a standalone package.

**Pros**:

- Strong module boundary
- Potential reuse by every target

**Cons**:

- Requires disruptive asset and target migration
- Duplicates or moves composer resources before the ownership boundary is clear
- Adds package complexity without a second independent consumer

### Layer a framework onto the current modules

Keep shared foundations in `ConvosComposer`, keep app-facing styles and
components in `Convos/Design System`, and document the ownership boundary.

**Pros**:

- Builds directly on current architecture
- Supports incremental migration
- Keeps shared values available to the composer
- Requires no new dependency

**Cons**:

- The framework spans two modules
- App components are not automatically reusable by extensions

## Decision

Adopt the layered framework.

Shared, value-only foundations live in `ConvosComposer.DesignConstants`.
Semantic colors remain asset-backed. App-facing typography, surface, and button
styles live in `Convos/Design System/Styles`. Reusable view patterns live in
`Convos/Design System/Components`.

Feature views remain responsible for copy, state, navigation, and business
behavior. The design system owns reusable appearance, layout, and interaction
states.

## Consequences

### Positive

- New work has a clear default path for typography, spacing, surfaces, and controls.
- Existing screens can migrate gradually.
- Common accessibility behavior is centralized.
- The visual catalog provides a review surface for light and dark mode.

### Negative

- Contributors must decide whether a primitive belongs in the shared composer or app layer.
- Some existing one-off styling remains until nearby feature work touches it.

### Neutral

- A standalone package can be reconsidered if another app or extension needs the
  full component layer.
- Exact branded typography may continue to use specialized views where native
  SwiftUI text cannot reproduce the intended line height.

## Implementation Notes

- Foundations: `ConvosCore/Sources/ConvosComposer/DesignConstants.swift`
- Styles and components: `Convos/Design System`
- Visual inventory: `Convos/Design System/DesignSystemCatalogView.swift`
- Usage guide: `docs/design-system.md`
- Representative migrations begin with settings rows, contact rows, badges,
  empty states, and informational sheets.

Every shared component should include previews for meaningful states. Changes to
foundations should be reviewed in light and dark mode and at large accessibility
text sizes.

## Related Decisions

- [ADR 012](./012-connections-architecture.md): Connections architecture
- [ADR 013](./013-connections-resolution.md): Connections resolution and picker

## References

- [Convos design system guide](../design-system.md)
