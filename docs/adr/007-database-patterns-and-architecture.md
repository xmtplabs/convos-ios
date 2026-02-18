# ADR-007: Database Patterns and Architecture

> **Status**: Proposed  
> **Author**: chaachaaa  
> **Created**: 2026-02-18  
> **Updated**: 2026-02-18  

## Context

Convos uses a sophisticated database architecture built on GRDB with specific patterns for data access, mutation, and concurrent access between the main app and notification service extension (NSE). The architecture has evolved to address several key challenges:

**Current Architecture Components:**
- **GRDB SQLite Database**: WAL mode with persistent WAL for multi-process access
- **Repository Pattern**: Read-only data access with reactive publishers
- **Writer Pattern**: Dedicated classes for data mutations and business logic
- **Database Models**: GRDB record types separate from domain models
- **Shared Database**: Single SQLite file in App Group container accessible by both main app and NSE

**Key Challenges Addressed:**
- **Multi-process Concurrency**: Main app and NSE need concurrent access to the same data
- **Reactive UI Updates**: SwiftUI views need to reactively update when data changes
- **Separation of Concerns**: Clear boundaries between data access patterns and business logic
- **XMTP Integration**: Synchronizing local data with XMTP network state
- **Testing**: Mockable components for unit testing

## Decision Drivers

- [x] **Multi-process Architecture**: NSE and main app need concurrent database access
- [x] **Performance Requirements**: Efficient queries and minimal UI blocking
- [x] **Reactive UI**: SwiftUI views need automatic updates when data changes
- [x] **Maintainability**: Clear patterns that scale across the growing codebase
- [x] **Testability**: Components must be mockable and testable in isolation
- [x] **XMTP Synchronization**: Local data must stay synchronized with XMTP network state
- [x] **Memory Efficiency**: Minimize memory usage in NSE extension

## Considered Options

### Option 1: Core Data

**Description**: Use Core Data for ORM with NSPersistentCloudKitContainer for multi-process access.

**Pros**:
- Native iOS framework with mature ecosystem
- Built-in multi-process coordination via NSPersistentCloudKitContainer
- Excellent SwiftUI integration via @FetchRequest
- Strong migration tools

**Cons**:
- Complex setup for multi-process scenarios
- CloudKit integration adds unnecessary complexity for private messaging
- Difficult to debug and profile
- Poor performance with complex queries
- Large memory footprint in NSE

### Option 2: SQLite with Manual Access

**Description**: Direct SQLite access with manual SQL queries and no abstraction layer.

**Pros**:
- Maximum performance control
- Minimal memory footprint
- Complete control over concurrency
- Predictable behavior

**Cons**:
- No reactive publishers for UI updates
- Manual memory management and error handling
- No type safety for queries
- High maintenance burden
- Difficult to test

### Option 3: GRDB with Repository/Writer Pattern

**Description**: GRDB SQLite wrapper with separated read (repositories) and write (writers) components.

**Pros**:
- Excellent multi-process support via WAL mode
- Type-safe query building
- Built-in reactive publishers (ValueObservation)
- Good performance with sophisticated optimization
- Clear separation between reads and writes
- Excellent testing support with in-memory databases
- Minimal memory footprint suitable for NSE

**Cons**:
- Learning curve for GRDB-specific patterns
- Additional abstraction layer over SQLite
- Manual synchronization logic required

## Decision

**We chose Option 3: GRDB with Repository/Writer Pattern**

The decision was driven by the need for:
1. **Reliable multi-process access** via WAL mode and persistent WAL
2. **Reactive UI updates** through GRDB's ValueObservation publishers
3. **Clear architectural boundaries** via repository/writer separation
4. **Excellent testing support** with mockable protocols and in-memory databases

## Consequences

### Positive

**Clear Separation of Concerns**:
- **Repositories**: Handle all read operations and provide reactive publishers
- **Writers**: Handle mutations with business logic validation
- **Database Models**: GRDB-specific models separate from domain models

**Excellent Multi-process Support**:
- WAL mode enables concurrent reads between main app and NSE
- Persistent WAL ensures NSE can always read current data
- Connection pooling with busy timeout handles lock contention gracefully

**Reactive Architecture**:
- ValueObservation provides efficient change notifications to SwiftUI views
- Automatic UI updates when data changes in background processes
- Combine integration enables sophisticated data flow patterns

**Testing Benefits**:
- All components implement protocols for easy mocking
- In-memory databases enable fast, isolated unit tests
- Writers can be tested independently of UI components

### Negative

**Learning Curve**:
- Developers need to understand GRDB-specific patterns
- Migration strategies require GRDB knowledge
- Query optimization requires understanding of GRDB's FTS and indexing

**Architectural Complexity**:
- Separate read/write patterns require discipline to maintain
- Database models must be kept in sync with domain models
- Migration logic can become complex with schema changes

### Neutral

**Performance Characteristics**:
- Excellent read performance via optimized SQLite queries
- Write performance depends on proper transaction batching
- Memory usage remains minimal for NSE requirements

## Implementation Notes

### Key Files and Components

**Database Management**:
- `DatabaseManager.swift`: Configures GRDB pool with WAL mode and multi-process settings
- `SharedDatabaseMigrator.swift`: Handles schema migrations and data transformations

**Repository Pattern**:
- Located in `ConvosCore/Sources/ConvosCore/Storage/Repositories/`
- Each repository focuses on read operations for specific domain areas
- Implements protocols for dependency injection (e.g., `ConversationsCountRepositoryProtocol`)
- Uses ValueObservation for reactive data streams

**Writer Pattern**:
- Located in `ConvosCore/Sources/ConvosCore/Storage/Writers/`  
- Handles all data mutations with business logic validation
- Marked `@unchecked Sendable` as GRDB provides thread safety via database queues
- Integrates with XMTP client for network synchronization

**Database Models**:
- Located in `ConvosCore/Sources/ConvosCore/Storage/Database Models/`
- GRDB Record types prefixed with `DB` (e.g., `DBConversation`)
- Separate from domain models to maintain clear architectural boundaries

### Multi-process Configuration

```swift
// WAL mode for concurrent access
config.journalMode = .wal

// Persistent WAL for NSE read access  
var flag: CInt = 1
sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, &flag)

// Connection pooling for concurrent readers
config.maximumReaderCount = 5
config.busyMode = .timeout(10.0)
```

### Testing Strategy

- Repositories implement protocols for dependency injection
- In-memory databases for fast, isolated unit tests
- Mock implementations available for all major components
- Writers tested independently of UI and network layers

## Related Decisions

- [ADR-002](./002-per-conversation-identity-model.md): Identity model affects database schema design
- [ADR-003](./003-inbox-lifecycle-management.md): Inbox lifecycle requires specific database patterns

## References

- [GRDB Documentation](https://github.com/groue/GRDB.swift)
- [SQLite WAL Mode](https://www.sqlite.org/wal.html)
- [GRDB Multi-process Access](https://github.com/groue/GRDB.swift/blob/master/Documentation/SharingADatabase.md)