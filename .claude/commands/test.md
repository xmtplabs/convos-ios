# Test

Run tests for the Convos project.

## Usage

```
/test [mode] [filter]
```

**Modes:**
- (default) - Full tests with local XMTP node (requires Docker)
- `isolated` - Only pure unit tests that don't need Docker (limited subset)
- `single` - Run a specific test by name

## Commands

### Full Test Suite (Default - Requires Docker)

Most tests require the local XMTP node:

```bash
./dev/test
```

This script will:
1. Start Docker containers (`./dev/up`)
2. Wait for XMTP node to be ready on port 5556
3. Run all tests
4. Stop containers when done

### Isolated Tests (No Docker)

A small subset of truly isolated tests that don't need any network:

```bash
./dev/test --unit
```

This only runs: `Base64URL|DataHex|Compression|Custom Metadata`

### Single Test

Run a specific test by name. **Note:** Most tests require Docker to be running first.

```bash
# Start Docker first (for most tests)
./dev/up

# Then run specific test
swift test --filter "TestClassName" --package-path ConvosCore
swift test --filter "TestClassName/testMethodName" --package-path ConvosCore

# When done
./dev/down
```

Examples:
```bash
# Run all tests in a test class
swift test --filter "SessionManagerTests" --package-path ConvosCore

# Run a specific test method
swift test --filter "SessionManagerTests/test_setActiveClientId" --package-path ConvosCore

# Run tests matching a pattern
swift test --filter "InboxLifecycle" --package-path ConvosCore
```

## Test Categories

| Category | Docker Required | Command |
|----------|-----------------|---------|
| Most tests | **Yes** | `./dev/test` |
| Isolated unit tests | No | `./dev/test --unit` |
| Single test (typical) | **Yes** | Start Docker, then `swift test --filter` |

## Docker Management

```bash
# Start XMTP node
./dev/up

# Stop XMTP node
./dev/down

# Check if running
docker ps | grep xmtp

# View logs
./dev/compose logs
```

## On Failure

1. **Docker not running**: `docker info` - make sure Docker Desktop is running
2. **XMTP node not ready**: Check port 5556 with `nc -z localhost 5556`
3. **View container logs**: `./dev/compose logs`
4. **Build failures**: Run `swift build --package-path ConvosCore` to see errors
5. **Restart fresh**: `./dev/down && ./dev/up`
