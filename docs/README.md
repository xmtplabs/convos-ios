# Convos Documentation

This directory contains project documentation, feature plans, and architecture decision records.

## Structure

```
docs/
├── README.md           # This file
├── TEMPLATE_PRD.md     # Template for new feature PRDs
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

1. Reference the PRD: "Review the PRD in docs/plans/[feature].md"
2. Use the `swift-architect` agent to validate technical design
3. Update the PRD as decisions are made
4. Mark tasks complete as they're implemented

## Architecture Decision Records

ADRs document significant architectural decisions. Create one when:
- Adding a new major dependency
- Changing core patterns or conventions
- Making tradeoffs that affect the codebase long-term

### ADR Template

```markdown
# ADR-[number]: [Title]

## Status
Proposed | Accepted | Deprecated | Superseded

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```

## Conventions

- Use kebab-case for file names: `feature-name.md`
- Keep PRDs updated as implementation progresses
- Archive completed PRDs by moving to `plans/archive/`
