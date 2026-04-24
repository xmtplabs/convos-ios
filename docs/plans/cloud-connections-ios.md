# Cloud Connections v0.1 — iOS Implementation Plan

> **Vocabulary:** "Cloud Connections" = Composio-brokered SaaS integrations (OAuth tokens stored server-side, tool calls proxied through Composio). Separate from "Device Connections" — the on-device Apple-SDK pathway in the `ConvosConnections` package. Both show up to the user as plain "Connections" in Settings; Cloud/Device is engineering vocabulary only.

## Context

Convos assistants are blind to users' real-world context. Cloud Connections let users link external SaaS services (starting with Google Calendar via Composio) and share access per-conversation, so the runtime can provision tools for the assistant.

This plan covers the **iOS side only**: data models, local storage, XMTP metadata sync, OAuth flow, and UI. It assumes the Convos backend will expose endpoints to proxy Composio API calls (keeping the Composio API key server-side).

---

## Architecture Summary

```
User taps "Connect Google Calendar"
  -> iOS calls Convos backend: POST /connections/initiate
  -> Backend calls Composio API, returns OAuth URL
  -> iOS opens URL in ASWebAuthenticationSession
  -> User completes OAuth consent
  -> Callback returns to iOS app
  -> iOS calls backend: POST /connections/complete
  -> Backend confirms with Composio, returns connection metadata
  -> iOS stores DBConnection in GRDB

User toggles grant in Conversation Info
  -> iOS writes DBConnectionGrant to GRDB
  -> iOS serializes grants as JSON into XMTP conversation metadata
  -> Runtime reads metadata on group_updated, provisions tools
```

---

## 1. Data Models (ConvosCore)

**New directory**: `ConvosCore/Sources/ConvosCore/Connections/`

### Connection.swift
```swift
public struct Connection: Codable, Identifiable, Sendable, Hashable {
    public let id: String                // Composio connected account ID
    public let serviceId: String          // "google_calendar"
    public let serviceName: String        // "Google Calendar"
    public let composioEntityId: String   // deviceId - scopes tokens in Composio to this device
    public let composioConnectionId: String
    public let status: ConnectionStatus
    public let connectedAt: Date
}

public enum ConnectionStatus: String, Codable, Sendable {
    case active, expired, revoked
}
```

### ConnectionGrant.swift
```swift
public struct ConnectionGrant: Codable, Sendable, Hashable {
    public let connectionId: String
    public let conversationId: String
    public let serviceId: String          // Denormalized for metadata serialization
    public let grantedAt: Date
}
```

### ConnectionsMetadataPayload.swift
The JSON payload stored as a string value under `profile.metadata["connections"]` on each sender's own profile — matches the runtime's schema in `connections.mjs`:

```swift
public struct ConnectionsMetadataPayload: Codable, Sendable {
    public let version: Int
    public var grants: [ConnectionGrantEntry]
}

public struct ConnectionGrantEntry: Codable, Sendable {
    public let id: String                   // grant identifier (grant_…)
    public let senderId: String             // XMTP inbox ID of the user who granted
    public let service: String              // canonical name, e.g. "google_calendar"
    public let provider: String             // "composio"
    public let scope: String                // "conversation" for v0.1
    public let composioEntityId: String     // deviceId — scopes Composio tokens to this device
    public let composioConnectionId: String // ca_…
    public let grantedAt: String            // ISO8601
}
```

**Wire-level layout:** grants live on each sender's **own** `ProfileUpdate` message (`metadata["connections"]`) rather than in a cross-user map. The runtime's `readSenderGrants` fetches the profile for `msg.senderId` and reads its `metadata.connections` directly — no map lookup needed. Each user writes only their own entries; the per-sender security scoping falls out naturally from "only the sender can author their own ProfileUpdate."

**Key insight on identity split:**

| Field | Value | Purpose |
|-------|-------|---------|
| Profile owner (inbox ID) | The sender's inbox ID in THIS conversation | Per-user security scoping — runtime matches against `msg.senderId` |
| `senderId` in the entry | Same as profile owner | Agent-profile fallback path carries sender explicitly |
| `composioEntityId` | `deviceId` (same everywhere) | Composio-side token scoping |
| `composioConnectionId` | Composio's connection ID (same everywhere) | Which Composio connection to use |

One connection, shared across N conversations — each conversation's metadata entry keyed by whichever inbox ID the user appears as in that conversation.

### GRDB Models
- `DBConnection.swift` in `Storage/Database Models/` - `FetchableRecord, PersistableRecord`
- `DBConnectionGrant.swift` in `Storage/Database Models/` - composite PK on (connectionId, conversationId)

---

## 2. Protobuf Extension (ConvosAppData)

**File**: `ConvosAppData/Sources/ConvosAppData/Proto/conversation_custom_metadata.proto`

Add field 7:
```protobuf
optional string connectionsJson = 7;  // JSON grants payload for runtime
```

Regenerate `conversation_custom_metadata.pb.swift` with `protoc --swift_out`.

**Why a JSON string in a proto field**: The runtime expects the grants as a JSON structure keyed by inbox ID. Embedding the JSON as a proto string field lets the iOS app serialize using the established protobuf pipeline (Base64URL + DEFLATE) while the runtime can extract and parse the JSON directly. No nested proto messages needed for a shape that may evolve on the runtime side.

---

## 3. XMTP Metadata Accessors

**File**: `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift`

Add computed property and update method following the existing pattern (`inviteTag`, `expiresAt`, etc.):

```swift
public var connectionsJson: String? { ... }
public func updateConnectionsJson(_ json: String) async throws { ... }
```

Uses `atomicUpdateMetadata(operation:modify:verify:)` with retry, same as all other metadata updates.

---

## 4. Database Migration

**File**: `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift`

Add after `"addConversationEmoji"` (the last migration):

```swift
migrator.registerMigration("createConnections") { db in
    try db.create(table: "connection") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("serviceId", .text).notNull()
        t.column("serviceName", .text).notNull()
        t.column("provider", .text).notNull()
        t.column("composioEntityId", .text).notNull()          // = deviceId
        t.column("composioConnectionId", .text).notNull()
        t.column("status", .text).notNull()
        t.column("connectedAt", .datetime).notNull()
    }
    try db.create(table: "connectionGrant") { t in
        t.column("connectionId", .text).notNull()
            .references("connection", onDelete: .cascade)
        t.column("conversationId", .text).notNull()
            .references("conversation", onDelete: .cascade)
        t.column("serviceId", .text).notNull()
        t.column("grantedAt", .datetime).notNull()
        t.primaryKey(["connectionId", "conversationId"])
    }
    try db.create(index: "connectionGrant_conversationId",
                  on: "connectionGrant", columns: ["conversationId"])
}
```

---

## 5. Repository and Writer

### ConnectionRepository.swift
`ConvosCore/Sources/ConvosCore/Connections/ConnectionRepository.swift`

GRDB `ValueObservation`-based queries:
- `observeConnections()` - all active connections for the user
- `observeGrants(for conversationId:)` - grants for a specific conversation
- `connections()` - one-shot read of all connections

Follows the pattern of existing repositories (e.g., `ConversationsCountRepository`).

### ConnectionGrantWriter.swift
`ConvosCore/Sources/ConvosCore/Connections/ConnectionGrantWriter.swift`

Handles granting/revoking + metadata sync:
1. Insert/delete `DBConnectionGrant` in GRDB
2. Determine the user's inbox ID **in this conversation** — Convos uses per-conversation identities, so fetch via the conversation's XMTP client (`client(for: conversationId).inboxId`), NOT a global identity
3. Read existing `connectionsJson` from the group's metadata (may contain other users' grants in groups)
4. Update the entry for the current inbox ID, leaving other users' entries untouched
5. Serialize updated payload and call `group.updateConnectionsJson(json)`

Needs: `DatabaseWriter` (GRDB), `InboxStateManager` (to resolve the conversation-specific inbox ID), XMTP group access.

**Concrete example:** Same user grants Google Calendar to Conv A (as `inbox_work`) and Conv B (as `inbox_friends`):
- Conv A metadata → `{ "inbox_work":    [{ composioConnectionId: "conn_abc", composioEntityId: "device_xyz", ... }] }`
- Conv B metadata → `{ "inbox_friends": [{ composioConnectionId: "conn_abc", composioEntityId: "device_xyz", ... }] }`

Same Composio connection referenced from both; the map key differs per conversation.

---

## 6. Backend API Integration

### New method on ConvosAPIClientProtocol
**File**: `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

Add to the protocol:
```swift
func initiateConnection(serviceId: String) async throws -> ConnectionInitiationResponse
func completeConnection(connectionRequestId: String) async throws -> ConnectionCompletionResponse
func listConnections() async throws -> [ConnectionResponse]
func revokeConnection(connectionId: String) async throws
```

The backend keeps the Composio API key server-side. The iOS app never talks to Composio directly.

**Backend endpoints needed** (iOS dependency, not built here):
- `POST /api/connections/initiate` - creates Composio connection request, returns OAuth URL
- `POST /api/connections/complete` - confirms connection after OAuth, returns connection metadata
- `GET /api/connections` - lists user's connected accounts
- `DELETE /api/connections/{id}` - revokes connection and deletes tokens from Composio

---

## 7. OAuth Flow

### OAuthSessionProvider protocol (ConvosCore)
`ConvosCore/Sources/ConvosCore/Connections/OAuthSessionProvider.swift`

```swift
public protocol OAuthSessionProvider: Sendable {
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL
}
```

### iOS implementation (ConvosCoreiOS)
`ConvosCoreiOS/Sources/ConvosCoreiOS/OAuthSessionProviderIOS.swift`

Implements using `ASWebAuthenticationSession`:
1. Present OAuth URL (from backend) in system browser
2. User consents on Google's OAuth screen
3. Composio handles the redirect chain
4. `ASWebAuthenticationSession` intercepts the callback URL scheme
5. Returns callback URL to caller

Callback URL scheme: `ConfigManager.shared.appUrlScheme` (e.g., `convos://`)

### ConnectionManager (ConvosCore)
`ConvosCore/Sources/ConvosCore/Connections/ConnectionManager.swift`

Orchestrates the full connect/disconnect flow:
```swift
public protocol ConnectionManagerProtocol: Sendable {
    func connect(serviceId: String) async throws -> Connection
    func disconnect(connectionId: String) async throws
    func refreshConnections() async throws -> [Connection]
}
```

Flow:
1. Call backend `initiateConnection` -> backend uses `entityId = deviceId` (from JWT) when calling Composio, returns OAuth URL + request ID
2. Call `OAuthSessionProvider.authenticate(url:)` -> user completes OAuth
3. Call backend `completeConnection` -> backend confirms with Composio, returns connection metadata (`composioEntityId = deviceId`, `composioConnectionId`)
4. Store `DBConnection` in GRDB
5. Return `Connection` to caller

**Device change handling (v0.1):** If the deviceId changes (wipe, reinstall, new device), the user needs to reconnect each service. Acceptable for v0.1 — connections are a per-device concept. The iOS app stores the connection's `composioEntityId` (= deviceId at connect time) in GRDB; if the current deviceId no longer matches, treat the connection as stale and prompt reconnect.

---

## 8. Feature Flag

**File**: `Convos/Config/FeatureFlags.swift`

Add `isConnectionsEnabled: Bool` (default `false` for v0.1).

---

## 9. UI: App Settings - Connections List

### ConnectionsListView.swift
`Convos/App Settings/ConnectionsListView.swift`

NavigationStack with List:
- Connected services section (if any): service icon, name, "Connected" status, tap to manage/disconnect
- "Add Connection" section: one row per available service (Google Calendar for v0.1)
- Tapping "Add" triggers the OAuth flow via `ConnectionManager`

### ConnectionsListViewModel.swift
`Convos/App Settings/ConnectionsListViewModel.swift`

`@Observable @MainActor` class:
- Observes `ConnectionRepository.observeConnections()`
- `connect(serviceId:)` -> delegates to `ConnectionManager`
- `disconnect(connectionId:)` -> delegates to `ConnectionManager`

### AppSettingsView.swift integration
**File**: `Convos/App Settings/AppSettingsView.swift`

Add section after Assistants, gated by `FeatureFlags.shared.isConnectionsEnabled`:
```swift
Section {
    NavigationLink { ConnectionsListView(...) } label: {
        Text("Connections").foregroundStyle(.colorTextPrimary)
    }
} footer: {
    Text("Share services with conversations")
}
```

---

## 10. UI: Conversation Info - Per-Conversation Grants

### ConversationConnectionsSection
Add to `ConversationInfoView.swift` as a new `@ViewBuilder` section property.

Shows one `FeatureRowItem` per connected service with a `Toggle`:
- Toggle on: creates grant, syncs to XMTP metadata
- Toggle off: revokes grant, syncs to XMTP metadata
- Only visible when user has connections and conversation has an assistant

Position: after `assistantSection`, before `convoCodeSection`.

### ConversationViewModel extensions
**File**: `Convos/Conversation Detail/ConversationViewModel.swift`

Add:
- `connections: [Connection]` observed from `ConnectionRepository`
- `grantedConnectionIds: Set<String>` observed from `ConnectionGrantRepository`
- `toggleConnectionGrant(_ connectionId: String)` calls `ConnectionGrantWriter`

---

## 11. Deep Linking

**File**: `Convos/DeepLinking/DeepLinkHandler.swift`

Extend `DeepLinkDestination`:
```swift
case connectionGrant(serviceId: String, conversationId: String)
```

Parse: `convos://connections/grant?service=google_calendar&conversationId=abc123`

Update `destination(for:)` to check for `/connections/grant` path before falling through to invite code parsing.

Route handling: navigate to the conversation, then present the connections toggle sheet pre-scrolled to the requested service.

---

## 12. Grant Request Cards (stretch for v0.1)

When the runtime sends a `grant_request` content type message:

1. Add `connectionGrantRequest` to `MessageContentType` enum
2. Parse the message content (service ID, reason text)
3. Render as an in-chat card with service icon, description, and "Grant Access" button
4. Tapping the button deep-links to `convos://connections/grant?service=...&conversationId=...`

This parallels the existing `assistantJoinRequest` pattern. Can be deferred to v0.2 if needed.

**Historical-message handling (v0.1):** no backfill is needed. The runtime-side `requestGrant` tool hasn't shipped, so no `connection_grant_request` messages exist in any conversation yet. Older clients that eventually receive one without the codec registered will store the codec's `fallback` string (`"The assistant asked to connect <service>"`) as plain text — acceptable, since those clients don't know about Connections at all. Once a client is upgraded, newly received messages decode and render as cards; previously-dropped-to-text messages stay as text (they're grant *requests*, not grants, so they expire naturally — the user just misses one prompt).

---

## File Summary

### New files to create
| File | Location | Purpose |
|------|----------|---------|
| `Connection.swift` | `ConvosCore/Connections/` | Domain model |
| `ConnectionGrant.swift` | `ConvosCore/Connections/` | Grant model |
| `ConnectionsMetadataPayload.swift` | `ConvosCore/Connections/` | JSON payload for XMTP metadata |
| `ConnectionManager.swift` | `ConvosCore/Connections/` | OAuth flow orchestrator |
| `ConnectionRepository.swift` | `ConvosCore/Connections/` | GRDB read queries |
| `ConnectionGrantWriter.swift` | `ConvosCore/Connections/` | Grant CRUD + metadata sync |
| `OAuthSessionProvider.swift` | `ConvosCore/Connections/` | Protocol for OAuth browser |
| `OAuthSessionProviderIOS.swift` | `ConvosCoreiOS/` | ASWebAuthenticationSession impl |
| `DBConnection.swift` | `ConvosCore/Storage/Database Models/` | GRDB record |
| `DBConnectionGrant.swift` | `ConvosCore/Storage/Database Models/` | GRDB record |
| `ConnectionsListView.swift` | `Convos/App Settings/` | Settings UI |
| `ConnectionsListViewModel.swift` | `Convos/App Settings/` | Settings VM |

### Existing files to modify
| File | Change |
|------|--------|
| `conversation_custom_metadata.proto` | Add `optional string connectionsJson = 7` |
| `conversation_custom_metadata.pb.swift` | Regenerate from proto |
| `XMTPGroup+CustomMetadata.swift` | Add `connectionsJson` accessor + update method |
| `SharedDatabaseMigrator.swift` | Add `createConnections` migration |
| `ConvosAPIClient.swift` | Add connection endpoint methods to protocol + impl |
| `FeatureFlags.swift` | Add `isConnectionsEnabled` |
| `AppSettingsView.swift` | Add Connections section |
| `ConversationInfoView.swift` | Add connections grant toggles section |
| `ConversationViewModel.swift` | Add connection/grant properties + toggle |
| `DeepLinkHandler.swift` | Add `connectionGrant` destination |

---

## Backend Dependencies (not built here)

The iOS app needs these backend endpoints before OAuth can work end-to-end:
- `POST /api/connections/initiate` - returns Composio OAuth URL
- `POST /api/connections/complete` - confirms connection, returns metadata
- `GET /api/connections` - lists user's connections
- `DELETE /api/connections/{id}` - revokes connection

These endpoints proxy to Composio's API, keeping the API key server-side.

---

## Open Questions

1. **Backend readiness**: Do the backend endpoints exist yet, or is that a parallel workstream?
2. **Trigger types**: For Google Calendar, which Composio trigger types should be included in the grant metadata? The PRD mentions `GOOGLE_CALENDAR_EVENT_STARTING`.
3. **Feature flag default**: Should connections be enabled by default in Dev/Local environments?
4. **Stale device handling**: How exactly to detect a changed deviceId and surface "reconnect" UX. v0.1 can simply mark connection as `.expired` when API calls fail.

---

## Verification

1. **Build**: `/build` succeeds with all new files
2. **Tests**: Unit tests for `ConnectionsMetadataPayload` serialization, `ConnectionRepository` queries, grant writer metadata sync
3. **Manual**: Enable feature flag in Dev -> Settings shows Connections -> OAuth flow opens browser -> Connection appears -> Toggle grant in Conversation Info -> Verify XMTP metadata contains `connectionsJson` field (via debug metadata viewer)
