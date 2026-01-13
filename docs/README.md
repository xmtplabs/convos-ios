# Convos Documentation

This directory contains project documentation, feature plans, and architecture decision records.

## Structure

```
docs/
├── README.md           # This file
├── TEMPLATE_PRD.md     # Template for new feature PRDs
├── TEMPLATE_ADR.md     # Template for Architecture Decision Records
├── plans/              # Feature PRDs and implementation plans
└── architecture/       # Architecture Decision Records (ADRs)
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

1. Copy `TEMPLATE_ADR.md` to `architecture/adr-[number]-[short-title].md`
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

### Using ADRs with Claude Code

The `swift-architect` agent can help with ADRs:

1. **Drafting**: "Help me write an ADR for our [system/decision]"
2. **Reviewing**: "Review this ADR for completeness"
3. **Understanding**: "Explain the decisions in architecture/adr-001-*.md"

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
