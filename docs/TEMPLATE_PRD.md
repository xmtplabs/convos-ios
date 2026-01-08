# Feature: [Feature Name]

> **Status**: Draft | In Review | Approved | In Progress | Complete
> **Author**: [Your Name]
> **Created**: [Date]
> **Updated**: [Date]

## Overview

Brief description of the feature and its purpose.

## Problem Statement

What problem does this feature solve? Why is it needed?

## Goals

- [ ] Goal 1
- [ ] Goal 2
- [ ] Goal 3

## Non-Goals

What is explicitly out of scope for this feature?

- Not doing X
- Not solving Y

## User Stories

### As a [user type], I want to [action] so that [benefit]

Acceptance criteria:
- [ ] Criteria 1
- [ ] Criteria 2

## Technical Design

### Architecture

How does this feature fit into the existing architecture?

- **Dependencies**: What existing code does it depend on?
- **New Components**: What new protocols, classes, or views are needed?

Note: Core logic/services → ConvosCore, iOS-specific implementations → ConvosCoreiOS, Views/ViewModels → Main App

### Data Model

Any new database tables, fields, or models?

```swift
// Example model
struct NewFeature: Codable {
    let id: String
    let name: String
}
```

### API Changes

Any new endpoints or changes to existing APIs?

### UI/UX

Describe the user interface changes. Include:
- Screens affected
- New views needed
- Navigation flow

## Implementation Plan

### Phase 1: [Phase Name]
- [ ] Task 1
- [ ] Task 2

### Phase 2: [Phase Name]
- [ ] Task 1
- [ ] Task 2

## Testing Strategy

- Unit tests for: [list components]
- Integration tests for: [list flows]
- Manual testing: [describe scenarios]

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Risk 1 | High/Medium/Low | How to address |

## Open Questions

- [ ] Question 1?
- [ ] Question 2?

## References

- Link to related PRDs
- Link to design files
- Link to relevant documentation
