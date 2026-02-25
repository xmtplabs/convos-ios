# Convos Documentation

This directory contains project documentation, feature plans, and architecture decision records.

## Structure

```
docs/
├── README.md           # This file
├── TEMPLATE_PRD.md     # Template for new feature PRDs
├── TEMPLATE_ADR.md     # Template for Architecture Decision Records
├── plans/              # Feature PRDs and implementation plans
└── adr/                # Architecture Decision Records (ADRs)
```

## PRD Workflow

### Creating a New Feature PRD

1. Copy `TEMPLATE_PRD.md` to `plans/[feature-name].md`
2. Fill in all sections
3. Review with team
4. Update status as work progresses

### Using PRDs with Claude Code

When working on a feature with Claude Code:

1. Use the `prd-writer` agent to help draft the PRD: "Help me write a PRD for [feature]"
2. Reference the PRD: "Review the PRD in docs/plans/[feature].md"
3. Use the `swift-architect` agent to validate technical design
4. Update the PRD as decisions are made
5. Mark tasks complete as they're implemented

### PRD Statuses

| Status | Meaning |
|--------|---------|
| **Draft** | Initial writeup, still collecting requirements |
| **In Review** | Ready for team feedback |
| **Approved** | Signed off, ready for implementation |
| **In Progress** | Currently being implemented |
| **Complete** | Feature shipped |

## Architecture Decision Records (ADRs)

ADRs document significant architectural decisions and the reasoning behind them. They serve as a historical record and help new team members understand why things are built the way they are.

### When to Write an ADR

Create an ADR when:
- Adding a new major dependency or framework
- Changing core patterns or conventions
- Making tradeoffs that affect the codebase long-term
- Choosing between multiple viable approaches
- Documenting existing architecture for posterity

### Creating a New ADR

1. Copy `TEMPLATE_ADR.md` to `adr/[number]-[short-title].md`
2. Use the next sequential number (check existing ADRs)
3. Fill in all sections, especially the alternatives considered
4. Set status to "Proposed" for team review
5. Update to "Accepted" once approved

### ADR Statuses

| Status | Meaning |
|--------|---------|
| **Proposed** | Under discussion, not yet approved |
| **Accepted** | Approved and in effect |
| **Deprecated** | No longer applies (but kept for history) |
| **Superseded** | Replaced by a newer ADR (link to it) |

### ADR Index

| ADR | Title | File |
|-----|-------|------|
| 001 | Decentralized Invite System with Cryptographic Tokens | `docs/adr/001-invite-system-architecture.md` |
| 002 | Per-Conversation Identity Model with Privacy-Preserving Push Notifications | `docs/adr/002-per-conversation-identity-model.md` |
| 003 | Inbox Lifecycle Management with LRU Eviction | `docs/adr/003-inbox-lifecycle-management.md` |
| 004 | Conversation Explode Feature | `docs/adr/004-explode-feature.md` |
| 005 | Profile Storage in Conversation Metadata | `docs/adr/005-profile-storage-in-conversation-metadata.md` |
| 006 | Lock Convo Feature | `docs/adr/006-lock-convo-feature.md` |
| 007 | Default Conversation Display Name and Emoji | `docs/adr/007-default-conversation-display-name.md` |
| 008 | Asset Lifecycle and Renewal Strategy | `docs/adr/008-asset-lifecycle-and-renewal.md` |
| 009 | Encrypted Conversation Images | `docs/adr/009-encrypted-conversation-images.md` |
| 010 | Public Preview Image Toggle for Invite Links | `docs/adr/010-public-preview-image-toggle.md` |

### Using ADRs with Claude Code

The `swift-architect` agent can help with ADRs:

1. **Drafting**: "Help me write an ADR for our [system/decision]"
2. **Reviewing**: "Review this ADR for completeness"
3. **Understanding**: "Explain the decisions in docs/adr/001-*.md"

### ADR Examples

Good ADR topics for Convos:

- **Invite System**: How invites work, why we use signed tokens, privacy considerations
- **Multi-Inbox Architecture**: Why users can have multiple identities, lifecycle management
- **Database Patterns**: Why GRDB, repository pattern, writer pattern separation
- **XMTP Integration**: How we integrate with XMTP, offline sync strategy
- **State Management**: Why @Observable over other patterns

### Documenting Existing Systems

When writing ADRs for existing features:

1. Research the current implementation
2. Interview team members about original decisions (if possible)
3. Document what you can infer from the code
4. Mark uncertain areas with "[INFERRED]"
5. Focus on the "why" more than the "what"

## Conventions

- Use kebab-case for file names: `feature-name.md`, `adr-001-decision-title.md`
- Keep documents updated as implementation progresses
- Archive completed PRDs by moving to `plans/archive/`
- Never delete ADRs - mark as deprecated or superseded instead
- Link related PRDs and ADRs to each other
