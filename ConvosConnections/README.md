# ConvosConnections

> **Library products**
>
> - `ConvosConnections` — the core package. All ship-worthy sources (Health, Calendar, Location, Contacts, Photos, Music, Motion, HomeKit) plus every payload type. Does **not** link Family Controls.
> - `ConvosConnectionsScreenTime` — optional add-on that provides `ScreenTimeDataSource`. Pulled out because the `com.apple.developer.family-controls` entitlement requires Apple's explicit approval for App Store distribution. Depend on this product only when you're ready to ship with that entitlement.

---


A reusable Swift package that lets a Convos user enable native iOS data sources ("connections") and deliver the resulting payloads into conversations so that assistants (AI agents) can consume them.

The package is deliberately **XMTP-agnostic**. It knows nothing about messaging, codecs, or encryption. It emits structured `ConnectionPayload` values through a `ConnectionDelivering` protocol that the host app implements.

## Scope

- Defines the `DataSource` protocol and ships concrete sources (initially `HealthDataSource`).
- Handles per-source authorization flows and background observation.
- Stores per-(connection, conversation) enablement state via an `EnablementStore` protocol — the host app provides the persistent implementation (GRDB in the Convos app).
- Provides a SwiftUI `ConnectionsDebugView` for inspecting authorization status, toggling enablement, and viewing recent payloads.
- Versions every payload body with a `schemaVersion` field so the wire format can evolve without breaking agents.

## What it deliberately does not do

- Send XMTP messages. The host app wraps payloads in a content type and sends them.
- Register XMTP content codecs. That belongs in the single-inbox refactor's codec-registration path (PR 713, checkpoint C6).
- Persist anything. All storage is pluggable; an `InMemoryEnablementStore` is provided for tests and the debug view.

## Architecture

```
┌────────────────────────────────────────────────────────┐
│ Host app (Convos)                                      │
│                                                        │
│  ┌──────────────────────────┐                          │
│  │ XMTPConnectionDelivering │  ← registers codec,      │
│  │ (implements Delivering)  │    wraps payload,        │
│  └────────────┬─────────────┘    sends to conversation │
│               │                                        │
│  ┌────────────▼─────────────┐                          │
│  │ GRDBEnablementStore      │  ← persists toggles      │
│  └────────────┬─────────────┘                          │
└───────────────┼────────────────────────────────────────┘
                │
┌───────────────▼────────────────────────────────────────┐
│ ConvosConnections                                      │
│                                                        │
│  ConnectionsManager  ←── orchestrates                  │
│         │                                              │
│         ├── DataSource (protocol)                      │
│         │     └── HealthDataSource (HealthKit)         │
│         │                                              │
│         ├── EnablementStore (protocol)                 │
│         │                                              │
│         └── ConnectionDelivering (protocol)            │
│                                                        │
│  ConnectionsDebugView  ←── SwiftUI inspector           │
└────────────────────────────────────────────────────────┘
```

## Enablement granularity

Enablement is keyed by `(ConnectionKind, conversationId)`. Per-assistant granularity was considered but deferred — everyone in an XMTP conversation receives every message, so a per-assistant toggle would not actually gate who sees the data. That dimension can be added later if rendering ever hides payloads from humans.

## Adding a new data source

1. Add a case to `ConnectionKind`.
2. Add a payload body type (e.g. `CalendarPayload`) with its own `schemaVersion`.
3. Add a case to `ConnectionPayloadBody`.
4. Implement a `DataSource` conformance.
5. Register it with the `ConnectionsManager` at launch.

See `HealthDataSource` for a reference implementation.
