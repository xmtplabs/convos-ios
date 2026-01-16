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

**IMPORTANT: Always follow these rules when writing Swift code to avoid lint errors.**

**Critical Rules (errors):**
- **No force unwrapping** (`!`) - Use `guard let`, `if let`, or optional chaining
- **No implicitly unwrapped optionals** - Use regular optionals with safe unwrapping
- **No assertions in non-test code** - Use Logger.error or Sentry instead of `assert`, `assertionFailure`, `precondition`, `preconditionFailure`

**Required Patterns:**
- `first(where:)` over `.filter { }.first` - More efficient
- `last(where:)` over `.filter { }.last` - More efficient
- `sorted().first` over `sorted()[0]` - Safer
- `contains(where:)` over `.filter { }.isEmpty == false` - Cleaner
- Implicit return in single-expression closures (not functions)
- Trailing closure only for single parameter closures
- Private over fileprivate unless file-level access needed

**Formatting Rules:**
- Sort imports alphabetically
- Max line length: 200 characters
- Max function body: 125 lines
- Max type body: 625 lines
- Max function parameters: 6
- Vertical whitespace: no blank lines after opening braces or before closing braces
- Operator usage whitespace required (e.g., `a + b` not `a+b`)

**Modifier Order (strict):**
```swift
// Correct order:
public override dynamic lazy final var property: Type
private(set) public var property: Type
```
Order: `acl` → `setterACL` → `override` → `dynamic` → `mutators` → `lazy` → `final` → `required` → `convenience` → `typeMethods` → `owned`

**Custom Rules:**
- Name constants enums `Constant` (not `Constants`)
- Use `enum Constant` (not `struct Constant`)
- Put `private enum Constant` at the **bottom** of the scope, not top

**File Headers:**
- Do NOT include `// Created by...` headers - they're forbidden

**Explicit Types:**
- Required for class/struct properties, NOT for local variables:
```swift
// ✅ Good
class MyClass {
    var name: String = ""  // Explicit type required
    func doSomething() {
        let local = "value"  // Local can infer type
    }
}
```

### Guard Preference
Prefer `guard` with early return over `if` with early return for validation and unwrapping:
```swift
// ✅ Good
guard let value = optional else { return nil }
return process(value)

// ❌ Avoid
if let value = optional {
    return process(value)
}
return nil
```

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
| `/setup` | Initialize session for convos-task (creates simulator, sets MCP defaults) |
| `/build` | Build the app (compile only) using "Convos (Dev)" scheme |
| `/build --run` | Build and launch in an unused simulator |
| `/test` | Run tests (ConvosCore by default) |
| `/lint` | Check code with SwiftLint |
| `/format` | Format code with SwiftFormat |
| `/firebase-token` | Get Firebase App Check debug token from simulator logs |

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

Six MCP servers are configured in `.mcp.json`:

- **XcodeBuildMCP**: Build and test the Xcode project directly
- **ios-simulator**: Interact with the iOS Simulator (launch, screenshot, etc.)
- **xmtp-docs**: Search and access XMTP protocol documentation
- **graphite**: Manage stacked PRs and branches (requires Graphite CLI v1.6.7+)
- **notion**: Access Notion workspace for documentation and notes
- **linear**: Access Linear issues, projects, and roadmap for task context

### Worktree DerivedData Isolation

The `/build` command automatically uses `-derivedDataPath .derivedData` to store build artifacts locally in each worktree. This prevents conflicts when multiple worktrees build the same project.

**Why this matters:**
- Prevents "module not found" errors when building extensions (e.g., NotificationService)
- Isolates build caches between parallel worktrees
- Each worktree can build independently without affecting others

**Troubleshooting:**
- If you get module errors, delete `.derivedData/` and rebuild: `rm -rf .derivedData`
- The `.derivedData/` folder is gitignored

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

### PRD-Driven Development with Graphite Stacking

Feature development follows a PRD workflow integrated with Graphite's PR stacking:

**Starting a New Feature:**
1. Run `convos-task new feature-name` to create a new worktree and Graphite branch
2. Use `prd-writer` agent to draft the PRD at `docs/plans/[feature].md`
3. Commit the PRD and create the first PR in the stack (this is always the plan PR)
4. Use `swift-architect` agent to design detailed technical implementation
5. Stack implementation PRs on top of the plan PR

**PR Stacking Strategy:**
- **First PR**: Always the plan/PRD document
- **Subsequent PRs**: Implementation work stacked on top of the plan
- **Checkpoints**: Create a new stacked PR when a chunk of work is "shippable" (compiles, tests pass, represents a logical unit)

**What constitutes a checkpoint:**
- A complete model or data layer change
- A full view/screen implementation
- A service or repository addition
- Any logically complete, reviewable unit of work

**Graphite Commands (Claude should use these):**
```bash
# Create a new branch stacked on current AND commit staged changes
gt create branch-name

# Amend the current branch's commit (automatically restacks descendants)
gt modify

# Create/update PRs for all branches from trunk to current
gt submit

# Navigate the stack
gt checkout branch-name  # Switch to specific branch
gt up                    # Move to child branch
gt down                  # Move to parent branch
gt top                   # Jump to tip of stack
gt bottom                # Jump to base of stack

# Sync with remote (cleans up merged branches, updates dependents)
gt sync

# View the current stack structure
gt log
gt log short             # Abridged version
```

**PRD Guidelines:**
- PRDs focus on **what** and **why**, not detailed **how**
- Avoid prescriptive code implementations in PRDs
- Leave technical design specifics to `swift-architect` agent
- Reference relevant ADRs for architectural context

**Example Feature Workflow:**
```
main
 └── feature-name-plan        # PR 1: PRD document
      └── feature-name-models  # PR 2: Data models
           └── feature-name-ui # PR 3: Views and ViewModels
```

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
convos-task new my-feature dev

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
- **DerivedData isolation**: Each worktree uses `.derivedData/` locally to avoid build conflicts (see XcodeBuildMCP Worktree Configuration)
- **Simulator auto-setup**: A dedicated simulator (`convos-<task-name>`) is created when the task starts

### Task Simulator Configuration

When `convos-task new` creates a task, it automatically:
1. Saves the task config to `.convos-task` file in the worktree root
2. Starts creating a dedicated simulator `convos-<task-name>` in the background
3. Launches Claude Code in a new terminal tab

**Session Initialization:** When Claude Code starts in a convos-task worktree:
1. A SessionStart hook detects `.convos-task` and prompts Claude to run `/setup`
2. Run `/setup` to:
   - Create the simulator if it doesn't exist yet
   - Set XcodeBuildMCP session defaults (simulator, project, scheme)
   - Save the simulator ID for `/build` to use

The `/build` command will automatically use the task's simulator from `.convos-task`:
```bash
# Read task config
cat .convos-task
# Returns: TASK_NAME=my-feature
#          SIMULATOR_NAME=convos-my-feature
```

Set `CONVOS_BASE_SIMULATOR` env var to change the source simulator (auto-detected by default).

### Git and Branch Management with Graphite

This project uses Graphite for PR management. A **Graphite MCP** is configured in `.mcp.json` that Claude must use for all `gt` commands.

**IMPORTANT: Claude must use the Graphite MCP tool (`mcp__graphite__run_gt_cmd`) for all gt commands.** Do NOT use Bash to run gt commands directly - use the MCP tool instead.

#### Workflow Overview

There are two workflows depending on task size:

**Small/Medium Tasks (single PR):**
1. Work on the current branch created by `convos-task new`
2. Commit changes normally with `git add` and `git commit`
3. When ready to submit, use `gt submit` via the Graphite MCP to create/update the PR

**Large Tasks (stacked PRs):**
For larger features that benefit from reviewable chunks, create stacked PRs:
1. Complete a reviewable chunk of work
2. Use `gt create` to create a new stacked branch with your changes
3. Continue working, creating new stacked branches at each checkpoint
4. Use `gt submit --stack` to submit the entire stack

#### Using the Graphite MCP

The Graphite MCP provides the `run_gt_cmd` tool. Examples:

```
# Submit current branch as PR
mcp__graphite__run_gt_cmd with args: ["submit", "--no-interactive"]

# Create a new stacked branch with staged changes
mcp__graphite__run_gt_cmd with args: ["create", "-am", "Add user profile feature"]

# View stack structure
mcp__graphite__run_gt_cmd with args: ["log", "short"]

# Sync with remote
mcp__graphite__run_gt_cmd with args: ["sync", "--no-interactive"]
```

#### Common Graphite Commands

| Command | Purpose |
|---------|---------|
| `gt submit` | Create/update PR for current branch |
| `gt submit --stack` | Submit entire stack of PRs |
| `gt create -am "msg"` | Create new stacked branch with commit |
| `gt modify -a` | Amend current commit (restacks descendants) |
| `gt sync` | Sync with remote, restack on latest main |
| `gt log short` | View stack structure |

#### When to Stack PRs

Create a new stacked PR when:
- Code compiles successfully
- Relevant tests pass
- Changes represent a complete, reviewable unit
- You're switching from one concern to another (e.g., models → views)

For small bug fixes or simple features, a single PR is fine - just commit normally and use `gt submit`.

#### Example: Large Feature with Stacked PRs

```
main
 └── feature-plan        # PR 1: PRD document
      └── feature-models  # PR 2: Data models
           └── feature-ui # PR 3: Views and ViewModels
```
