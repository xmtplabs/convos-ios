# Designer Mode

Instructions for designers using Claude Code. Include this file in your session by telling Claude "I'm a designer" or "use designer mode".

## Quality Gates (Required Before Finishing)

Before considering any task complete, Claude MUST run these checks in order:

1. **Format code**: `/format`
2. **Lint code**: `/lint` - fix any errors
3. **Build the app**: `/build` - must succeed with no errors
4. **Run tests**: `/test` - all tests must pass
5. **Simplify code**: Use the `code-simplifier` subagent to reduce complexity
6. **Review code**: Use the `code-reviewer` subagent to check for issues

If any step fails or reveals issues, fix them before proceeding. Do not skip these steps.

To run the subagents, ask Claude:
- "Run the code-simplifier agent on the changes"
- "Run the code-reviewer agent on the changes"

## Branch Protection

**NEVER push directly to these branches:**
- `main`
- `dev`

**Always work on feature branches:**
1. Create a new branch for your work: `git checkout -b designer/feature-name`
2. Make your changes
3. Commit to your feature branch
4. Use `gt submit` to create a PR for review

If you accidentally try to push to main or dev, STOP and create a feature branch instead.

## Workflow

1. **Understand the task** - Read relevant code, ask clarifying questions
2. **Plan first** - Use plan mode for anything beyond trivial changes
3. **Make changes** - Keep them focused and minimal
4. **Run quality gates** - Format, lint, build, test, simplify, review (see above)
5. **Commit and PR** - Use `gt submit` to create a PR (never push directly to main/dev)

## Getting Help

- If you're unsure about something, ask Claude to explain
- If Claude seems confused about the codebase, have it search for examples
- If builds fail with confusing errors, try `/build` again or ask for help
- For Firebase token issues, run `/firebase-token`

## Commands Reference

| Command | Purpose |
|---------|---------|
| `/format` | Format code with SwiftFormat |
| `/lint` | Check code with SwiftLint |
| `/build` | Build the app |
| `/build --run` | Build and launch in simulator |
| `/test` | Run tests |
| `/firebase-token` | Get Firebase debug token from logs |
