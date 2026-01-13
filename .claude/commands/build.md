# Build

Build the Convos iOS app using the Dev scheme.

## Usage

```
/build [scheme]
```

- Default scheme: "Convos (Dev)"
- Other schemes: "Convos (Local)", "Convos (Prod)"

## Command

Build the app for the iOS Simulator:

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -configuration Dev \
  | xcpretty
```

If xcpretty is not available, run without it:

```bash
xcodebuild build \
  -project Convos.xcodeproj \
  -scheme "Convos (Dev)" \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -configuration Dev
```

## Alternative: Use XcodeBuildMCP

If XcodeBuildMCP is configured, use the MCP tool instead for better integration:

```
mcp__XcodeBuildMCP__build with scheme "Convos (Dev)"
```

## On Failure

If the build fails:
1. Check for Swift compilation errors in the output
2. Run `swiftlint` to check for lint issues
3. Verify all dependencies are resolved in Package.resolved
4. Try cleaning: `xcodebuild clean -scheme "Convos (Dev)" -configuration Dev`
