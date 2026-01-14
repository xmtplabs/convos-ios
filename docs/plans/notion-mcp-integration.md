# Plan: Notion MCP Integration

## Summary

Integrate Notion MCP server with Claude Code to chat with Notion pages, fetch content, and manage comments.

## Capabilities Confirmed

**Yes, Notion MCP supports:**
- ✅ Fetching individual pages with full content (`fetch` tool)
- ✅ Fetching and adding comments (`add-comment` tool)
- ✅ Searching across workspace (`search` tool)
- ✅ Creating/updating pages (`create-pages`, `update-page` tools)
- ✅ Editing pages in Markdown format

**21 total tools available** including data source (database) operations.

## Recommended Approach: Hosted OAuth

### Why Hosted (not self-hosted)?

| Approach | Status | Pros | Cons |
|----------|--------|------|------|
| **Hosted OAuth** | ✅ Active | Always updated, no token management, officially supported | Requires browser auth |
| Self-hosted npx | ⚠️ Sunsetting | No browser needed | Deprecated, not monitored, manual token setup |

Notion's official statement on the self-hosted repo:
> "We may sunset this local MCP server repository in the future. Issues and pull requests here are not actively monitored."

**Bottom line:** Use hosted. It's the only supported path forward.

## Setup Steps

### 1. Add Notion MCP Server

```bash
claude mcp add notion --transport http https://mcp.notion.com/mcp
```

### 2. Authenticate

On first use, Claude Code will open a browser for Notion OAuth:
- Log in to Notion
- Select workspace
- Grant permissions
- Done (token managed automatically)

### 3. Verify Setup

```bash
# Check server is configured
claude mcp list

# In Claude Code, check status
/mcp
```

## Usage Examples

Once configured:
- "Fetch the page at https://notion.so/your-page-id"
- "Search for pages about 'architecture'"
- "Add a comment 'Reviewed' to the PRD page"
- "What are the comments on [page URL]?"

## Security

- OAuth token managed by Notion (no local storage)
- Permissions granted per-workspace during auth
- Can revoke access from Notion settings anytime

## Verification

1. Run `claude mcp list` - should show "notion" server
2. Start Claude Code and run `/mcp` - should show notion connected
3. Test: "Search notion for 'test'" - should return results
