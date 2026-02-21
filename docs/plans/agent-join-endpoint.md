# iOS brief: triggering an agent to join a conversation

## Backend endpoint

`POST /api/v2/agents/join`

- Uses the same JWT authentication as other authenticated endpoints.
- Header:
  - `X-Convos-AuthToken: <jwt>`
- Body:
  - `{ "slug": "<invite-slug>" }`

## iOS implementation requirements

1. Generate an invite slug for the conversation (same flow currently used for user-to-user invites).
2. Call `POST /api/v2/agents/join` with JWT auth header and slug body.
3. Handle responses:
   - `200 { success: true, joined: true }` → agent is joining the conversation.
   - `503 NO_AGENTS_AVAILABLE` → no idle agents available; show a “try again later” message.
   - `504 AGENT_POOL_TIMEOUT` → pool timeout; retry or surface an error state.
   - `502 AGENT_PROVISION_FAILED` → provisioning failed; show an error state.

## UX notes

- The join call can take up to ~30 seconds.
- Show a loading state while waiting.
- No explicit polling is required after success.
  - The agent appears as a new member via existing XMTP group membership updates.

## Out of scope for iOS

- No new auth flow (reuse existing JWT).
- No invite URL construction (backend handles this).
- No status polling endpoint integration needed.
