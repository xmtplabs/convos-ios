# iOS brief: publish-on-share for builder-flow agent templates

## Context

Two surfaces show agent-template contacts and need a Share button:

- The standalone agent-template contact card
  (`Convos/Contacts/AgentTemplateContactCardView.swift`), opened from the
  Contacts tab.
- The unified `ContactDetailView`
  (`Convos/Contacts/ContactDetailView.swift`), opened by tapping an agent
  in a conversation's member list or a chat-bubble avatar.

Templates created via deep-link land with a `publishedUrl` already set on
profile data, so the share sheet renders immediately. Templates created
via the in-app builder flow land in `draft` and carry no `publishedUrl`,
so the Share row has nothing to seed.

For those builder-flow rows we tap a single backend endpoint that returns
the canonical `publishedUrl`, hand it to the iOS share sheet, and persist
it back so the next visit short-circuits to the cached path.

## Backend endpoint

`POST /api/v2/agent-templates/:id/publish?status=published`

- Same JWT auth as the rest of the v2 API
  (`X-Convos-AuthToken: <jwt>`).
- No request body. The `?status=published` query handles both branches
  the backend takes internally:
  - First-publish (`firstPublishedAt: null` -> a `draft` row): sets
    `firstPublishedAt = now`, sets status to `published`, returns the
    serialized template.
  - Re-publish (`firstPublishedAt` already set -> `unlisted` /
    `published` / `archived`): bumps version, preserves the existing
    status, returns the serialized template. The `?status=` query is
    honored only when the row is currently `draft` (the
    PATCHed-back-to-draft case), by design.
- Response 200: serialized agent template. Fields the iOS client reads:
  - `id: String`
  - `status: String`
  - `publishedUrl: String?` (non-null whenever status is not `"draft"`)
- Error responses we surface to the user as a generic share failure:
  - 403 - caller is not the template owner.
  - 404 - template id unknown.
  - 400 / 5xx - anything else.

We deliberately do not PATCH the status. PATCH is the only way to flip
`unlisted` -> `published`, but for the iOS share button the URL works the
same either way - the recipient can open it. Promoting `unlisted` to
`published` is a directory-visibility change, not a shareability change,
and isn't part of the share button's intent.

## iOS implementation requirements

1. Add a `ConvosAPI.AgentTemplate` decodable carrying just the fields we
   consume today (`id`, `status`, `publishedUrl`). Define it next to the
   other `ConvosAPI` request/response types so a future detail fetch can
   share the shape. No request body model needed.

2. Add a method on `ConvosAPIClient`
   (`ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`, near the
   `// MARK: - Agents` block that hosts `requestAgentJoin`):

   ```swift
   func publishAgentTemplate(id: String) async throws -> ConvosAPI.AgentTemplate
   ```

   Builds a single POST request via
   `authenticatedRequest(for: "v2/agent-templates/\(id)/publish",
   method: "POST", queryParameters: ["status": "published"])` with no
   body. A private `decodeAgentTemplateResponse(...)` helper handles
   status-code mapping: 2xx -> decode into `ConvosAPI.AgentTemplate`,
   400/403/404 -> the corresponding `APIError` case, anything else ->
   `APIError.serverError`. All branches log structured detail
   (`PATCH /POST` style isn't needed - there's one call).

3. Plumb the new method through `ConvosAPIClientProtocol`, `MockAPIClient`,
   `MockInboxesService`, `SessionManagerProtocol`, `SessionManager`, the
   `TestStubAPIClientDefaults` default-impl extension, and the two
   `TestSessionManager` proxies in `ConvosTests`. Same forwarding pattern
   as `requestAgentJoin`.

4. Update `AgentTemplateContactCardView`:

   - Always render a share row. If `agentTemplateContact.publishedURL` is
     set, use the existing `ContactDetailShareRow` (SwiftUI `ShareLink`).
     Otherwise render a `ContactDetailActionRow` labelled "Share" that
     drives the publish-then-share flow. Disable it while the request is
     in flight (label flips to "Sharing...") and when `session == nil`.
   - On success, persist the returned URL via
     `AgentTemplateContactsWriterProtocol.upsert(templateId:
     addedViaConversationId: profile:)`. Re-pass the contact's current
     `displayName`, `emoji`, `descriptionText`, `avatarURL`, and
     `agentVerification` in the snapshot - the writer's
     most-recent-wins rule wholesale-replaces the row's profile fields
     from the snapshot, so missing fields would blank out existing data.
   - Auto-present the iOS share sheet with the returned URL via a thin
     `ShareSheetPresenter` (UIActivityViewController wrapper, mirroring
     the one in `ConversationShareView.swift`).
   - On failure, log via `Log.error(String(describing: error))` and
     surface a "Couldn't share right now, try again." alert. No retry.

5. Update `ContactDetailView` for the same UX from member-list and
   chat-bubble entry points:

   - Add `@State` for the in-memory `resolvedAgentTemplateShareURL`,
     `isPublishingAgentTemplate`, `isAgentTemplateShareSheetPresented`,
     `publishAgentTemplateErrorMessage`.
   - Render the share row whenever `contact.agentTemplateId != nil`,
     branching on `publishedURL` the same way as the standalone card.
   - Seed `resolvedAgentTemplateShareURL` on appear from the freshest
     source available, in this order:
     1. `contact.agentTemplatePublishedURL` (overlaid by
        `Contact.resolved(...)` from the per-conversation member
        profile - the authoritative source, but lags until the agent's
        profile broadcast and the local membership sync land).
     2. `session.messagingService().agentTemplateContactsRepository()
        .fetchContact(templateId:)` against `DBAgentTemplateContact` -
        the cached URL written by any prior publish-on-share flow on
        this template (this view or the standalone card). Lets a
        repeat visit skip the POST until the member profile catches
        up. Sync `throws` call; treat misses and errors as a no-op
        and fall through to the publish-and-share row.
   - On success, persist locally via the writer obtained from
     `session.messagingService().agentTemplateContactsWriter()`. Best
     effort - persistence failures are logged but don't block the share.
   - Bundle the new share concerns into a `ContactDetailShareModifier`
     view modifier (sheet-presenter background + "Couldn't share" alert
     + the `onAppear` seed) so the body's modifier chain stays under the
     CLAUDE.md type-check budget.

6. Auth wiring: no new flow. `ConvosAPIClient.authenticatedRequest`
   already attaches the `X-Convos-AuthToken` header from the SIWE-bound
   or device JWT slot, which the agent-templates routes accept (same
   `authOrAgentApiKeyAuth` middleware as the other v2 endpoints).

## UX notes

- The POST is fast (single DB write + revalidation), so a brief inline
  "Sharing..." label is sufficient. No 30s budget like `requestAgentJoin`.
- After a successful publish, the row should switch to the cached
  `ContactDetailShareRow` on the next render so a repeat tap is instant.
  For the standalone agent-template card, this falls out of writing
  `publishedURL` back via the writer (the card reads
  `AgentTemplateContact.publishedURL` directly from
  `DBAgentTemplateContact`). For `ContactDetailView`, the seed step
  consults `DBAgentTemplateContact` as a fallback so a fresh view
  construction on a different conversation still gets the cached URL
  without re-POSTing.
- The agent-template's own profile data will eventually carry the
  `publishedUrl` once the server-side flow propagates it; our local
  write is a UX optimization, not the source of truth. Once member
  profile sync surfaces the URL, the `contact.agentTemplatePublishedURL`
  branch takes over and the `DBAgentTemplateContact` fallback becomes
  unused.

## Out of scope

- PATCH `/api/v2/agent-templates/:id` for any reason. The share button is
  POST-only.
- Status downgrades, archiving, slug edits, or any other agent-template
  mutations from the iOS share path.
- Promoting `unlisted` to `published` as a side effect of tapping Share.
  See the Context section - the share URL works either way.
- Reusing the new `ConvosAPI.AgentTemplate` model for list / detail
  fetches - we'll grow it when we wire those endpoints up.

## Verification

- Unit-test the new client method against the existing mock URLSession
  pattern in `ConvosCoreTests` (model the test on the `requestAgentJoin`
  coverage):
  - 200 returns the decoded template (with `publishedUrl` populated).
  - 403 maps to `APIError.forbidden`.
  - 404 maps to `APIError.notFound`.
  - 400 with a structured backend body maps to
    `APIError.badRequest(_:)` carrying the raw JSON / message.
- Manual: trigger the builder flow on the Dev env. Logger lines in
  `publishAgentTemplate` will print:
  - `publishAgentTemplate POST <url>` then a 2xx and the share sheet
    rendering the returned URL.
  - On second presentation, the row should already be the cached
    `ContactDetailShareRow` (no POST).
- Repeat the manual test from the member-list and chat-bubble entry
  points on a builder-flow agent that does not yet carry a `publishedUrl`.
  Expect the same single-POST behavior.
- Run `swift test --package-path ConvosCore` (Docker up) before pushing
  per the `CLAUDE.md` testing gate.
- Run `/lint` and `/format` before commit; pre-commit hook will block on
  remaining violations.
