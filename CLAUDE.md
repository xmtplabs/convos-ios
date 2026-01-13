# Convos iOS - Codebase Best Practices

This document contains project-specific conventions and best practices for the Convos iOS codebase.

## Architecture & Organization

### Project Structure
- **ConvosCore**: Swift Package containing all core business logic, models, services, repositories, writers, GRDB database, and XMTP client
- **ConvosCoreiOS**: iOS-specific implementations needed by ConvosCore (e.g., `UIImage` handling, push notification registration)
- **Main App (Convos)**: Views and ViewModels only (SwiftUI with UIKit integration where needed)
- **App Clips**: Separate target for lightweight experiences
- **Notification Service**: Extension for push notification handling

### Module Architecture
- All business logic, models, and services go in `ConvosCore`
- iOS-specific code that ConvosCore needs goes in `ConvosCoreiOS`
- Views and ViewModels go in the main app target
- Use protocols for dependency injection (e.g., `SessionManagerProtocol`)

### XMTP SDK Abstraction Pattern
To enable testability and avoid tight coupling to the XMTP iOS SDK, Convos uses protocol wrappers around XMTP types:

- **`XMTPClientProvider`**: Protocol that mirrors the XMTP SDK's client interface
- Allows dependency injection of mock XMTP clients in tests
- Prevents direct usage of XMTP SDK types throughout the codebase
- Enables testing without requiring live XMTP network connections

**Pattern:**
```swift
// ✅ Good - Use the protocol wrapper
func myFunction(client: any XMTPClientProvider) { }

// ❌ Bad - Direct XMTP SDK usage
func myFunction(client: XMTPiOS.Client) { }
```

This pattern applies to other XMTP types as well - prefer protocol wrappers for dependency injection and testability.

## SwiftUI Conventions

### State Management
- **Modern Observation Framework**: Use `@Observable` with `@State` for new code
  ```swift
  @Observable
  class MyViewModel {
      var property: String = ""
  }

  // In views:
  @State private var viewModel = MyViewModel()
  ```
- Legacy code may still use `ObservableObject` with `@StateObject`/@ObservedObject`

### Button Pattern
Always extract button actions to avoid closure compilation errors:
```swift
// ✅ Good
let action = { /* action code */ }
Button(action: action) {
    // view content
}

// ❌ Bad - causes compilation issues
Button(action: { /* action */ }) {
    // view content
}
```

### Preview Support
Use `@Previewable` for preview state variables:
```swift
@Previewable @State var text: String = "Preview"
```

## Code Style & Formatting

### SwiftFormat Configuration
- Trim whitespace always
- Use closure-only for stripping unused arguments
- Braces follow K&R style, opening brace on the same line (not Allman)
- Trailing commas in multi-line collections and parameter lists

### SwiftLint Rules
Key enforced rules:
- No force unwrapping
- Prefer `first(where:)` over filter operations
- Use explicit types for public interfaces
- Sort imports alphabetically
- Private over fileprivate
- No implicitly unwrapped optionals

### Naming Conventions
- ViewModels: `ConversationViewModel`, `ProfileViewModel`
- Views: `ConversationsView`, `MessageView`
- Storage: `SceneURLStorage`, `DatabaseManager`
- Repositories: `ConversationsCountRepository`
- Use descriptive names over abbreviations

## Dependency Management

### Swift Package Manager (SPM)
All dependencies managed through SPM. See `ConvosCore/Package.swift` for current versions.

### Environment Configuration
- Use `ConfigManager` for environment-specific settings
- Environments: Production, Development, Local
- Firebase configuration per environment

## Deep Linking

### URL Handling Architecture
- `SceneURLStorage`: Coordinates URL handling between SceneDelegate and SwiftUI
- `ConvosSceneDelegate`: Handles both Universal Links and custom URL schemes
- `DeepLinkHandler`: Validates and processes deep links
- Store pending URLs for cold launch scenarios

## Logging & Debugging

### Logger Configuration
```swift
Logger.configure(environment: environment)
Logger.info("Message")
Logger.error("Error message")
```
- Production vs development logging levels
- Environment-specific configuration

## Testing Conventions

### Mock Data
- Use `.mock` static methods for preview/test data
- Example: `ConversationViewModel.mock`

### Test Organization
- Unit tests in `ConvosTests`
- Core logic tests in `ConvosCoreTests`
- UI tests in separate target

## Security Best Practices

- Never commit secrets or API keys
- Use environment variables for sensitive configuration
- Validate all deep links before processing
- Use Firebase App Check for API protection

## Performance Guidelines

### Image Handling
- Use `AvatarView` with built-in caching
- Lazy load images where appropriate
- Handle image state (loading, loaded, error)

### SwiftUI Performance
- Use `@MainActor` for UI-related classes
- Minimize view body complexity
- Extract complex views into separate components

## Build & Release

### Build Commands
```bash
# Check for linting issues
swiftlint

# Auto-fix linting issues
swiftlint --fix

# Format code
swiftformat .

# Run tests (Local environment on iOS Simulator)
xcodebuild test -scheme "Convos (Local)" -destination "platform=iOS Simulator,name=iPhone 17"

# Build for device (Local environment)
xcodebuild build -scheme "Convos (Local)" -configuration Local

# Clean build folder
xcodebuild clean -scheme "Convos (Local)" -configuration Local
```

### Xcode Project Settings
- Minimum iOS version: 26.0
- Swift language mode: 5
- Single project structure with local SPM packages

## Migration Guidelines

### ObservableObject to @Observable
When migrating from `ObservableObject`:
1. Remove `ObservableObject` conformance
2. Add `@Observable` macro and `import Observation`
3. Remove `@Published` property wrappers
4. Change `@StateObject`/`@ObservedObject` to `@State` in views

## Important Notes

- **No trailing whitespace** on any lines
- **Don't add comments** unless specifically requested
- **Prefer editing existing files** over creating new ones
- **Follow existing patterns** in neighboring code
- **Check dependencies** before using any library

---

## Claude Code Workflow

This project is configured for Claude Code CLI with specialized subagents, slash commands, and MCP tools.

### Slash Commands

| Command | Description |
|---------|-------------|
| `/build` | Build the app using "Convos (Dev)" scheme |
| `/test` | Run tests (ConvosCore by default) |
| `/lint` | Check code with SwiftLint |
| `/format` | Format code with SwiftFormat |

### Subagents

Specialized agents for different tasks. Invoke explicitly or let Claude delegate automatically.

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| `swift-architect` | Architecture decisions, module design (read-only, uses Opus) | Planning new features, major refactors |
| `code-simplifier` | Reduce complexity, improve readability | After writing code, cleanup |
| `swiftui-specialist` | SwiftUI views, state management | Creating/modifying UI |
| `test-writer` | Generate unit tests | After implementing features |
| `code-reviewer` | Review changes, check quality | Before committing |

**Example usage:**
```
Use the swift-architect agent to review the SessionManager design
```

### MCP Tools

Two MCP servers are configured in `.mcp.json`:

- **XcodeBuildMCP**: Build and test the Xcode project directly
- **ios-simulator**: Interact with the iOS Simulator (launch, screenshot, etc.)

### Testing

Use the `./dev/test` script for running tests. **Most tests require Docker** for the local XMTP node:

```bash
# Full test suite (starts Docker automatically)
./dev/test

# Isolated unit tests only (no Docker) - limited subset
./dev/test --unit

# Run a single test (Docker usually required)
./dev/up  # Start Docker first
swift test --filter "TestClassName" --package-path ConvosCore
./dev/down  # Stop when done
```

### PRD-Driven Development

Feature development follows a PRD workflow:

1. Create PRD from template: `docs/TEMPLATE_PRD.md` → `docs/plans/[feature].md`
2. Use `prd-writer` agent to draft the PRD (problem statement, user stories, high-level approach)
3. Use `swift-architect` agent to design detailed technical implementation
4. Implement with other agents as needed
5. Update PRD status as work progresses

**PRD Guidelines:**
- PRDs focus on **what** and **why**, not detailed **how**
- Avoid prescriptive code implementations in PRDs
- Leave technical design specifics to `swift-architect` agent
- Reference relevant ADRs for architectural context

### Pre-commit Hooks

A pre-commit hook is available at `.claude/hooks/pre-commit.sh` that:
- Runs SwiftFormat on staged files
- Runs SwiftLint with auto-fix
- Blocks commits with unfixable errors

To install:
```bash
ln -sf ../../.claude/hooks/pre-commit.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### Parallel Task Management

The `convos-task` script (`.claude/scripts/convos-task`) automates working on multiple features simultaneously using git worktrees and Graphite.

**Setup:**
```bash
# Add to PATH in ~/.zshrc or ~/.bashrc
export PATH="$HOME/Code/convos-ios/.claude/scripts:$PATH"
alias ct="convos-task"
```

**Why this matters for Claude Code:**
- Each worktree is a **separate Claude Code session** with independent conversation history
- Allows working on multiple features without losing context or switching branches
- Integrates with Graphite's stacking workflow

**Basic Usage:**
```bash
# Create new task (creates worktree + Graphite branch + launches Claude)
convos-task new my-feature-name

# Or stack on specific parent
convos-task new my-feature main

# List all active tasks
convos-task list

# Switch to existing task (opens Claude in new terminal)
convos-task switch my-feature-name

# Submit PR via Graphite
convos-task submit my-feature-name

# Sync with Graphite stack
convos-task sync my-feature-name

# Clean up when done (removes worktree + branch)
convos-task cleanup my-feature-name
```

**Workflow Example:**
```bash
# Main repo: working on retry-errors
cd ~/Code/convos-ios

# Start parallel task in new worktree
convos-task new push-notifications
# → Opens new terminal with Claude at ~/Code/convos-ios-push-notifications
# → Branch stacked on current branch via Graphite

# Continue working on retry-errors in original session
# Work on push-notifications in new session
# Both Claude sessions are completely independent
```

**Key Points:**
- Each worktree has its own conversation history (no context sharing between sessions)
- Worktrees share the same `.claude/` configuration, MCP tools, and hooks
- Docker services (e.g., local XMTP node) are shared across worktrees
- Graphite branches are automatically stacked on current branch unless parent specified
- Use `ct` as shorthand for `convos-task`
