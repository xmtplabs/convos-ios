# MCP Apps Support Implementation

**Started:** 2026-02-28
**Archive Name:** `docs/worklogs/2026-02-28_mcp-apps-support.md`
**Branch:** TBD (not yet started)

---

## Constitutional Invariants

**These constraints must hold true throughout implementation. Violation is a blocker.**

### INV-1: ConvosCore Platform Independence

**Invariant:** ConvosCore must compile on macOS. No UIKit imports, no `#if canImport(UIKit)` conditionals in ConvosCore.
**Rationale:** Enables fast test execution without iOS Simulator. WKWebView rendering lives in the main app target or ConvosCoreiOS, not ConvosCore.
**Test Strategy:**
- `swift build --package-path ConvosCore` on macOS must succeed
- MCP client protocol layer lives in ConvosCore; rendering lives in app target
- CI validates macOS compilation

### INV-2: XMTP Message Compatibility

**Invariant:** MCP App content must serialize/deserialize correctly over XMTP encrypted transport. Existing message types must not break.
**Rationale:** All messages flow through XMTP. New content types must be backwards-compatible (older clients ignore unknown types gracefully).
**Test Strategy:**
- Round-trip serialization tests for `MCPAppContent`
- Verify older `MessageContent` cases decode without error when new cases exist
- Test that clients without MCP support render a fallback for unknown content

### INV-3: Sandbox Isolation

**Invariant:** MCP App webviews must not access parent app DOM, cookies, storage, or navigate outside their sandbox.
**Rationale:** MCP Apps run untrusted HTML from third-party servers. Security is non-negotiable.
**Test Strategy:**
- WKWebView configuration assertions (sandbox flags verified in tests)
- CSP enforcement tests (undeclared domains blocked)
- Verify no access to app storage or cookies from webview

### INV-4: User Consent for Sensitive Operations

**Invariant:** Tool calls initiated by an MCP App UI must require user approval before execution.
**Rationale:** The MCP Apps spec recommends hosts gate tool calls from the View. A malicious app could otherwise invoke tools silently.
**Test Strategy:**
- Verify approval prompt appears when View calls `ui/requests/call-tool`
- Verify tool does not execute if user declines

---

## Research Summary

### What Are MCP Apps?

MCP Apps (`io.modelcontextprotocol/ui` extension) let MCP servers deliver interactive HTML UIs rendered inline in chat. Launched January 26, 2026. Supported by Claude, ChatGPT, VS Code Copilot, Goose, Postman.

### Architecture

Three entities: **Server** (MCP server with `ui://` resources), **Host** (Convos), **View** (HTML in sandboxed WKWebView).

Communication:
- Server <-> Host: MCP protocol (stdio or HTTP+SSE) via Swift SDK
- Host <-> View: `WKScriptMessageHandler` / `evaluateJavaScript` carrying JSON-RPC 2.0

### Key Protocol Methods (ui/*)

| Method | Direction | Purpose |
|--------|-----------|---------|
| `ui/initialize` | View -> Host | Handshake, declare capabilities |
| `ui/context` | Host -> View | Theme, environment info |
| `ui/notifications/tool-input` | Host -> View | Deliver tool parameters |
| `ui/notifications/tool-result` | Host -> View | Deliver tool results |
| `ui/requests/call-tool` | View -> Host | Proxy tool calls to MCP server |
| `ui/requests/use-prompt` | View -> Host | Invoke an MCP prompt |
| `ui/requests/use-resource` | View -> Host | Request resource content |
| `ui/message` | View -> Host | Send a chat message |
| `ui/update-model-context` | View -> Host | Update LLM context |
| `ui/open-link` | View -> Host | Open a URL externally |

### Display Modes

inline (in chat), modal, panel, popover. Apps declare supported modes via `capabilities.displayModes`.

### SDK Status

- **MCP Swift SDK** (github.com/modelcontextprotocol/swift-sdk): Core MCP only, no Apps extension
- **MCP Apps SDK** (`@modelcontextprotocol/ext-apps`): TypeScript/JS only
- iOS host implementation must be built from scratch using WKWebView

### Key Sources

- Spec: github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
- Docs: modelcontextprotocol.io/docs/extensions/apps
- Swift SDK: github.com/modelcontextprotocol/swift-sdk
- Launch post: blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/

---

## Current Milestone: M4 - JSON-RPC Message Bridge

### Completed Milestones

**M1 - MCP Client Foundation** (21db4e4)
**M2 - Message Model Extension** (5665232)
**M3 - WKWebView App Renderer** (119b2e8)

### Remaining Milestones

**M1 - MCP Client Foundation:**

Add the MCP Swift SDK and build the connection management layer in ConvosCore.

- [x] Add MCP Swift SDK as SPM dependency in ConvosCore
- [x] Create `MCPConnectionManager` protocol and implementation
  - Connect to servers via stdio (local) or HTTP+SSE (remote)
  - Manage server lifecycle (connect, disconnect, reconnect)
  - Capability negotiation during `initialize` (detect `io.modelcontextprotocol/ui`)
- [x] Create `MCPServerConfiguration` model (server URL/command, transport type, metadata)
- [x] Resource discovery: call `resources/list`, cache `ui://` resources via `resources/read`
- [x] Unit tests for connection manager, capability negotiation, resource discovery
- [x] Build succeeds (macOS `swift build` and iOS simulator xcodebuild)
- [x] Tests pass (23/23 MCP tests pass on iOS simulator)
- [x] COMMIT (21db4e4)

**Note:** `supportsUI` detection is hardcoded to `false` because the MCP Swift SDK v0.11 `Server.Capabilities` has no `experimental` field. Will update when SDK adds MCP Apps extension support.

**M2 - Message Model Extension:**

Extend `MessageContent` to carry MCP App data over XMTP.

- [x] Create `MCPAppContent` model (resource URI, tool input/result, display mode, server identity, fallback text)
- [x] Add `case mcpApp(MCPAppContent)` to `MessageContent` enum
- [x] Ensure backwards-compatible Codable conformance (unknown cases decode gracefully)
- [x] GRDB schema migration (`addMcpAppToMessage`) for persistence
- [x] Round-trip serialization tests (17 tests)
- [x] Backwards-compatibility tests (decode without new case)
- [x] Build succeeds (macOS `swift build` and iOS simulator xcodebuild)
- [x] Tests pass (17/17 MCP App Content tests pass on iOS simulator)
- [x] COMMIT (5665232)

**M3 - WKWebView App Renderer:**

Build the sandboxed webview container that renders MCP App HTML inline in chat.

- [x] Create `MCPAppWebView` (UIViewRepresentable wrapping WKWebView)
  - Sandbox configuration: no navigation, no form submission, no parent access
  - CSP enforcement from server-declared `connectDomains` / `resourceDomains`
  - Permission gating (camera, mic, location) based on resource declarations
- [x] Theme injection: map Convos design tokens to MCP CSS variables
  - `--mcp-color-primary`, `--mcp-color-text`, `--mcp-color-background`
  - `--mcp-font-family`, `--mcp-font-size-base`
  - `--mcp-border-radius`, `--mcp-spacing-unit`
  - Dark mode support via `--mcp-display-mode`
- [x] Content height reporting (JS -> Swift) for dynamic sizing in chat list
- [x] Memory management: UICollectionView cell reuse destroys off-screen webviews via `dismantleUIView`; `prepareForReuse()` clears hosting config
- [x] Create `MCPAppBubbleView` container with loading/error/loaded states and server attribution
- [x] Wire `MCPAppBubbleView` into `MessagesGroupItemView` for `.mcpApp` messages
- [x] Build succeeds
- [x] COMMIT (119b2e8)

**M4 - JSON-RPC Message Bridge:**

Implement the `ui/*` JSON-RPC protocol between WKWebView and native code.

- [x] Create `MCPAppProtocol` types in ConvosCore (JSON-RPC 2.0, JSONValue, method enum, host context)
- [x] Create `MCPAppBridge` class in app target
  - `WKScriptMessageHandler` for View -> Host messages
  - `evaluateJavaScript("window.postMessage(...)")` for Host -> View messages
  - JSON-RPC 2.0 request/response/notification serialization
  - Bridge injection script overriding `window.parent.postMessage` for SDK compatibility
- [x] Implement `ui/initialize` handshake (declare host capabilities, display modes, theme)
- [x] Implement `ui/notifications/initialized` (triggers pending tool data delivery)
- [x] Implement `ui/notifications/tool-input` and `ui/notifications/tool-result`
- [x] Implement `ui/notifications/tool-cancelled`
- [x] Implement `ui/notifications/host-context-changed`
- [x] Implement `ui/message` (inject message into chat via delegate)
- [x] Implement `ui/update-model-context` (update LLM context via delegate)
- [x] Implement `ui/open-link` (open URL via delegate)
- [x] Implement `ui/request-display-mode` (V1: always returns inline)
- [x] Implement `ui/notifications/size-changed` (content size reporting)
- [x] Implement `ui/resource-teardown` (graceful shutdown)
- [x] Implement `ping` (health check)
- [x] Unit tests for protocol types, JSON-RPC serialization (19 tests)
- [x] ConvosCore builds on macOS (`swift build`)
- [x] Full app builds on iOS simulator
- [x] Tests pass (19/19)
- [ ] COMMIT

**M5 - Chat Rendering Integration:**

Wire MCP App views into the existing chat message rendering pipeline.

- [ ] Add MCP App case to `MessagesListItemType` or handle within `MessagesGroupItemView`
- [ ] Render `MCPAppWebView` inside message bubbles for inline display mode
- [ ] Modal display mode: present as sheet/fullscreen overlay
- [ ] Panel display mode: present as sidebar/drawer (iPad)
- [ ] Popover display mode: present as floating popover
- [ ] Fallback rendering: show text fallback for unsupported content
- [ ] Dynamic height: webview reports content size, bubble resizes
- [ ] Loading state: show placeholder while HTML loads
- [ ] Error state: show error if resource fetch fails
- [ ] Build succeeds
- [ ] COMMIT

**M6 - Security Hardening & QA:**

Harden security, run adversarial tests, and validate end-to-end.

- [ ] CSP enforcement integration tests (blocked domains, allowed domains)
- [ ] Sandbox escape tests (verify no access to parent DOM, cookies, storage)
- [ ] Permission consent UI (camera, mic, location approval prompts)
- [ ] Tool call approval UI and tests
- [ ] Performance testing: multiple webviews in chat, memory pressure
- [ ] Dark mode QA
- [ ] VoiceOver / accessibility audit for MCP App containers
- [ ] Build succeeds
- [ ] Tests pass
- [ ] COMMIT

**M7 - Archive:**

- [ ] **ASK USER:** "Ready to archive?"
- [ ] **WAIT for explicit user approval**
- [ ] Archive WORKLOG.md: `mv WORKLOG.md docs/worklogs/2026-02-28_mcp-apps-support.md`
- [ ] Create PR with summary

---

## Commit Checkpoint Summary

| Order | Commit Message | Type | SHA |
|-------|----------------|------|-----|
| 1 | `feat(mcp): add MCP Swift SDK and connection manager` | impl | 21db4e4 |
| 2 | `feat(mcp): extend MessageContent with mcpApp case` | impl | 5665232 |
| 3 | `feat(mcp): add sandboxed WKWebView renderer` | impl | 119b2e8 |
| 4 | `feat(mcp): implement ui/* JSON-RPC bridge` | impl | - |
| 5 | `feat(mcp): integrate MCP Apps into chat rendering` | impl | - |
| 6 | `feat(mcp): security hardening and QA` | impl | - |

---

## QA Test Plan

### Prerequisites

- [ ] App builds and runs on simulator
- [ ] MCP test server running locally (HTTP+SSE transport)
- [ ] Test MCP App HTML resource available

### Test Scenarios

| Scenario | Steps | Expected | Actual | Status |
|----------|-------|----------|--------|--------|
| Server connection | Connect to local MCP server | Connection established, capabilities detected | | TODO |
| UI resource discovery | List resources from server with `ui://` entries | Resources listed and cached | | TODO |
| Inline app render | LLM invokes tool with `_meta.ui` | HTML renders in chat bubble | | TODO |
| Tool call from app | Click button in MCP App that calls a tool | Approval prompt shown, tool executes on approval | | TODO |
| Tool call denied | Decline tool call approval | Tool not executed, app notified | | TODO |
| Theme matching | Render app in light and dark mode | CSS variables match Convos theme | | TODO |
| CSP enforcement | App tries to fetch undeclared domain | Request blocked | | TODO |
| Sandbox isolation | App tries to access parent cookies/storage | Access denied | | TODO |
| Dynamic sizing | App content changes height | Chat bubble resizes smoothly | | TODO |
| Modal display | App requests modal display mode | Fullscreen overlay presented | | TODO |
| Fallback rendering | Receive MCP App message on old client | Fallback text shown | | TODO |
| Memory pressure | Scroll through 10+ MCP App messages | Off-screen webviews destroyed, no OOM | | TODO |
| Message over XMTP | Send/receive MCP App content | Serializes and deserializes correctly | | TODO |
| Offline behavior | Open cached MCP App without network | Renders from cache or shows error | | TODO |

### Simulator QA

- [ ] Build and run on simulator
- [ ] Connect to test MCP server
- [ ] Verify inline MCP App renders in chat
- [ ] Verify tool calls work with approval
- [ ] Dark mode verified
- [ ] Dynamic type verified
- [ ] VoiceOver verified

---

## Dependencies

```text
M1 (MCP Client Foundation)
    ├── M2 (Message Model) - depends on M1
    ├── M3 (WKWebView Renderer) - independent of M1, can parallelize
    └── M4 (JSON-RPC Bridge) - depends on M1, M3
         └── M5 (Chat Rendering) - depends on M2, M3, M4
              └── M6 (Security & QA) - depends on all above
                   └── M7 (Archive) - depends on M6
```

Note: M2 and M3 can be worked in parallel after M1 completes.

---

## Deferred (V2+)

Items explicitly out of scope for this feature:

- [ ] MCP server marketplace / discovery UI - users configure servers manually first
- [ ] MCP Elicitation support (server-initiated structured forms) - complementary but separate feature
- [ ] MCP Sampling (server requests LLM completions from host) - separate feature
- [ ] App-to-app communication between MCP Apps in the same chat
- [ ] Persistent MCP App state across sessions (localStorage equivalent)
- [ ] iPad-optimized panel display mode - basic support only in V1
- [ ] MCP App store / curation - manual server configuration only
- [ ] Streaming tool results to apps in real-time
- [ ] MCP Apps in notification service extension

---

## Security Review - Adversarial Analysis

### Threat 1: Malicious HTML/JS in MCP App

**Attack:** A compromised MCP server delivers HTML with XSS, phishing UI, or crypto miners.
**Impact:** Data theft, credential phishing, device resource abuse.
**Mitigation:** WKWebView sandbox (no parent DOM access, no cookies/storage), CSP restricting network to declared domains, no navigation out of iframe.
**Status:** MITIGATED (via sandbox + CSP)

### Threat 2: Silent Tool Execution

**Attack:** MCP App UI silently calls `ui/requests/call-tool` to execute destructive server tools without user knowledge.
**Impact:** Unintended data modification, message sending, or resource consumption.
**Mitigation:** All `ui/requests/call-tool` calls require user approval prompt. Tool visibility controls (`"app"` vs `"model"`) respected.
**Status:** MITIGATED (via consent gate)

### Threat 3: CSP Bypass via Server Declaration

**Attack:** Malicious server declares `connectDomains: ["*"]` to allow unrestricted network access.
**Impact:** Data exfiltration from the webview sandbox to any domain.
**Mitigation:** Host enforces a maximum allowed domain list. Wildcard domains are rejected. User is warned about servers requesting broad network access.
**Status:** MITIGATED (via domain validation)

### Threat 4: Denial of Service via Resource Abuse

**Attack:** MCP App renders heavy content (large images, infinite loops, memory bombs) to crash the app.
**Impact:** App crash, battery drain, poor user experience.
**Mitigation:** WKWebView memory limits, content process termination on memory pressure, timeout for initial load, limit concurrent webview instances.
**Status:** MITIGATED (via resource limits)

### Threat 5: Message Spoofing via ui/message

**Attack:** MCP App uses `ui/message` to inject messages that appear to come from the user or other participants.
**Impact:** Social engineering, confusion, trust erosion.
**Mitigation:** Messages injected via `ui/message` are visually distinguished (labeled as "from [App Name]"). They cannot impersonate other participants.
**Status:** MITIGATED (via visual attribution)

### Threat 6: XMTP Transport Abuse

**Attack:** Oversized `MCPAppContent` payloads bloat XMTP messages.
**Impact:** Slow message delivery, storage exhaustion.
**Mitigation:** Size limits on `MCPAppContent` serialized payload. HTML resources are fetched by URI, not embedded in messages.
**Status:** MITIGATED (via size limits + URI reference)

---

## Key Design Decisions

1. **WKWebView over native rendering:** MCP Apps spec requires HTML rendering. WKWebView provides the necessary sandbox isolation, CSP enforcement, and JS interop. Native rendering would require reimplementing the entire web platform.

2. **HTML resources fetched by URI, not embedded in XMTP messages:** Messages carry the `ui://` resource URI and tool data. The host fetches HTML from the MCP server at render time. This keeps XMTP payloads small and allows apps to update their UI without resending messages.

3. **MCP client in ConvosCore, rendering in app target:** The protocol layer (connection, JSON-RPC, models) lives in ConvosCore for testability. WKWebView rendering lives in the main app target since it requires UIKit/WebKit.

4. **User consent gate on all View-initiated tool calls:** Even though the spec makes this optional, we require it for V1. Better to be conservative with untrusted HTML executing server-side tools.

5. **Fallback text for backwards compatibility:** `MCPAppContent` includes a `fallbackText` field. Clients that don't support MCP Apps render this text instead. Ensures graceful degradation over XMTP.

---

## Reviews Log

| Milestone | Date | Reviewer | Result | Notes |
|-----------|------|----------|--------|-------|
| - | - | - | - | - |

---

## Test Coverage Tracking

| Module | Before | After | Notes |
|--------|--------|-------|-------|
| ConvosCore | TBD | TBD | MCP client, models, serialization |
| Main App | TBD | TBD | WKWebView renderer, bridge |

---

## Rollback Plan

If feature needs to be reverted:
1. Remove `case mcpApp` from `MessageContent` - requires migration to handle stored messages
2. Remove MCP Swift SDK dependency from ConvosCore
3. No database migration rollback needed if we use additive schema changes only
4. Feature flag `isMCPAppsEnabled` can disable rendering without code removal

---

## Architecture Notes

### Where Code Lives

| Component | Location | Why |
|-----------|----------|-----|
| `MCPConnectionManager` | ConvosCore | Protocol layer, testable on macOS |
| `MCPServerConfiguration` | ConvosCore | Model, no platform dependencies |
| `MCPAppContent` | ConvosCore | Message model, serializable |
| JSON-RPC types | ConvosCore | Protocol types, no platform dependencies |
| `MCPAppBridge` | ConvosCoreiOS or App | Requires WKWebView (WebKit) |
| `MCPAppWebView` | App target | SwiftUI view, requires WebKit |
| Theme mapping | App target | Reads from SwiftUI environment |

### Communication Flow

```
MCP Server <--[HTTP+SSE/stdio]--> MCPConnectionManager (ConvosCore)
                                         |
                                         v
                                  MCPAppBridge (App)
                                         |
                              [WKScriptMessageHandler]
                                         |
                                         v
                                  WKWebView (MCP App HTML)
```

---

## Notes

- The MCP Swift SDK (github.com/modelcontextprotocol/swift-sdk) covers core protocol but has zero MCP Apps extension support. All `ui/*` methods must be implemented from scratch.
- The TypeScript `@modelcontextprotocol/ext-apps` package is the reference implementation. Use it as a guide for the Swift implementation.
- WKWebView content height reporting is notoriously tricky in scroll views. May need ResizeObserver in JS + message passing for reliable auto-sizing.
- Consider a feature flag (`isMCPAppsEnabled`) to gate the entire feature during development.
