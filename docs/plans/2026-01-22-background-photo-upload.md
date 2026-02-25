# Background Photo Upload Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable photo uploads to continue when the app is backgrounded, with progress reporting and manual retry for failures.

**Architecture:** Define `BackgroundUploadManagerProtocol` in ConvosCore with implementation in ConvosCoreiOS. Use background URLSession with delegate-based progress callbacks and continuation-based completion (not polling). Persist upload state to GRDB for crash recovery. Failed uploads surface to the user for manual retry.

**Eager Upload Pattern:** Photo upload starts immediately when the user selects a photo from the picker (not when they tap Send). This provides a better UX by allowing the upload to complete in the background while the user composes their message. When Send is tapped, if the upload is already complete, the message is sent immediately.

**Multiple Concurrent Uploads:** The system supports multiple photos uploading and sending concurrently:
1. User selects Photo A → upload starts immediately
2. User taps Send → Photo A queued to send (upload may still be in progress)
3. User selects Photo B → new upload starts (Photo A continues independently)
4. User taps Send → Photo B queued to send
5. Each photo sends via XMTP when its upload completes (order depends on upload completion)

Each eager upload has its own tracking key and state stored in `OutgoingMessageWriter.eagerUploads` dictionary. When Send is tapped, the current `trackingKey` is captured and cleared, allowing a new photo to be selected immediately. The view layer (`currentEagerUploadKey`) only tracks the *currently selected* photo, not all in-flight uploads.

**Edge Case - Selecting new photo before Send:** If user selects Photo A, then selects Photo B *without* tapping Send for Photo A:
- Photo A's upload is **cancelled** (user changed their mind)
- Photo B's upload starts fresh
- Only Photo B is shown in UI and can be sent

This differs from the "Send then select new" flow where Photo A's upload continues because the user committed to sending it.

**Immediate UI Update Requirement:** When the user taps Send, messages MUST appear in the messages list immediately - not after upload completes. This means:
1. Photo message saves to database immediately → appears in UI with upload progress indicator
2. Text message (if any) saves to database immediately after photo → appears in UI
3. Both messages are visible while photo upload is still in progress
4. XMTP sends happen in order in the background (photo first, then text)

**Message Queue Architecture:** To ensure correct ordering while allowing immediate UI updates:
1. Messages save to DB with `status = .pending` immediately when Send is tapped
2. A background queue processes pending messages in order for each conversation
3. Photo messages wait for upload completion before XMTP send
4. Text messages wait for any preceding photo in the same "send batch" to complete
5. This ensures: Photo A sends → Text A sends → Photo B sends → Text B sends

**Example Flow - Photo + Text sent together:**
```
User taps Send with Photo + "Check this out!"
  ├─ t=0ms: Photo message saved to DB (status=pending) → appears in UI
  ├─ t=1ms: Text message saved to DB (status=pending) → appears in UI
  ├─ t=0-5000ms: Photo upload completes in background
  ├─ t=5001ms: Photo XMTP send completes → status=sent
  └─ t=5002ms: Text XMTP send completes → status=sent
```

**Example Flow - Text sent while photo still uploading:**
```
User sends Photo A (upload starts)
User types "Here's the photo" and taps Send
  ├─ Text message saved to DB (status=pending) → appears in UI immediately
  ├─ Text waits in queue behind Photo A
  ├─ Photo A upload completes → Photo A sends via XMTP
  └─ Text sends via XMTP (in correct order, after photo)
```

**Tech Stack:** URLSession background configuration, URLSessionTaskDelegate, GRDB for persistence, Swift Concurrency (async/await with CheckedContinuation)

---

## Use Cases

| # | Scenario | Mechanism |
|---|----------|-----------|
| 1 | User selects photo → upload starts immediately | Eager upload via `startEagerUpload()` |
| 2 | User selects photo, backgrounds app → upload continues | Background URLSession |
| 3 | User selects photo, backgrounds app → upload + XMTP send | Background URLSession + recovery on foreground |
| 4 | User removes photo before sending → upload cancelled | `cancelEagerUpload()` |
| 5 | User taps Send with completed upload → immediate send | `sendEagerPhoto()` bypasses re-upload |
| 6 | Push notification with photo → prefetch to cache | Notification Service Extension (separate plan) |

**This plan covers Use Cases 1-5.** Use Case 6 (NSE photo prefetching) should be a separate plan.

---

## iOS Background Execution Constraints

| Mechanism | Time Limit | Notes |
|-----------|------------|-------|
| Background URLSession completion | ~30 seconds | App woken when upload finishes |
| App backgrounding | ~30 seconds | Varies by system state |
| `beginBackgroundTask` | ~30 seconds | Request additional time |

**Key constraint**: When background URLSession completes and wakes the app, we have ~30 seconds to initialize XMTP client and send the message. This may not be enough time. The plan handles this by persisting state and allowing manual retry.

---

## Current State

- `ConvosAPIClient.uploadAttachment()` uses `URLSession.shared.data(for:)` (synchronous)
- `PhotoUploadProgressTracker` tracks stage only (preparing/uploading/publishing), not percentage
- No background URLSession configuration
- Uploads fail silently when app is backgrounded
- No persistence of upload state for recovery

## Target State

- Uploads continue when app is backgrounded
- Upload progress shows percentage (0-100%)
- Upload state persists to database for crash recovery
- If XMTP send fails in background, message shows "retry" option in UI
- User can manually retry failed uploads/sends

---

## Task 1: Add Upload Progress Percentage to PhotoUploadProgressTracker

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Messaging/PhotoUploadProgressTracker.swift`
- Create: `ConvosCore/Tests/ConvosCoreTests/PhotoUploadProgressTrackerTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import ConvosCore

@Suite("PhotoUploadProgressTracker Tests")
struct PhotoUploadProgressTrackerTests {
    @Test("Setting progress updates both stage and percentage")
    func testSetProgressUpdatesStageAndPercentage() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setProgress(stage: .uploading, percentage: 0.5, for: key)

        let progress = tracker.progress(for: key)
        #expect(progress?.stage == .uploading)
        #expect(progress?.percentage == 0.5)

        tracker.clear(key: key)
    }

    @Test("Progress percentage defaults to nil when only stage is set")
    func testStageOnlyHasNilPercentage() {
        let tracker = PhotoUploadProgressTracker.shared
        let key = "test-upload-\(UUID().uuidString)"

        tracker.setStage(.preparing, for: key)

        let progress = tracker.progress(for: key)
        #expect(progress?.stage == .preparing)
        #expect(progress?.percentage == nil)

        tracker.clear(key: key)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --package-path ConvosCore --filter PhotoUploadProgressTrackerTests`
Expected: FAIL - `setProgress` and `progress(for:)` methods don't exist

**Step 3: Write minimal implementation**

```swift
import Foundation
import Observation

public enum PhotoUploadStage: Sendable, Equatable {
    case preparing
    case uploading
    case publishing
    case completed
    case failed

    public var label: String {
        switch self {
        case .preparing: "Preparing..."
        case .uploading: "Uploading..."
        case .publishing: "Sending..."
        case .completed: ""
        case .failed: "Failed"
        }
    }

    public var isCompleted: Bool {
        self == .completed
    }

    public var isFailed: Bool {
        self == .failed
    }

    public var isInProgress: Bool {
        switch self {
        case .preparing, .uploading, .publishing:
            true
        case .completed, .failed:
            false
        }
    }
}

public struct PhotoUploadProgress: Sendable, Equatable {
    public let stage: PhotoUploadStage
    public let percentage: Double?

    public init(stage: PhotoUploadStage, percentage: Double? = nil) {
        self.stage = stage
        self.percentage = percentage
    }
}

@Observable
public final class PhotoUploadProgressTracker: @unchecked Sendable {
    public static let shared: PhotoUploadProgressTracker = PhotoUploadProgressTracker()

    private var progressMap: [String: PhotoUploadProgress] = [:]
    private let lock: NSLock = NSLock()

    private init() {}

    public func setStage(_ stage: PhotoUploadStage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressMap[key] = PhotoUploadProgress(stage: stage, percentage: nil)
    }

    public func setProgress(stage: PhotoUploadStage, percentage: Double?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressMap[key] = PhotoUploadProgress(stage: stage, percentage: percentage)
    }

    public func progress(for key: String) -> PhotoUploadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return progressMap[key]
    }

    public func stage(for key: String) -> PhotoUploadStage? {
        lock.lock()
        defer { lock.unlock() }
        return progressMap[key]?.stage
    }

    public func clear(key: String) {
        lock.lock()
        defer { lock.unlock() }
        progressMap.removeValue(forKey: key)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --package-path ConvosCore --filter PhotoUploadProgressTrackerTests`
Expected: PASS

**Step 5: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Messaging/PhotoUploadProgressTracker.swift ConvosCore/Tests/ConvosCoreTests/PhotoUploadProgressTrackerTests.swift
git commit -m "feat: add percentage tracking to PhotoUploadProgressTracker"
```

---

## Task 2: Add PendingPhotoUpload Database Model

Persist upload state for crash recovery and retry. When the app is terminated mid-upload, this record allows us to surface a retry option to the user.

**Security Note:** We do NOT persist encryption keys. On retry, we start fresh: get the original image from ImageCacheContainer, re-compress, re-encrypt (new keys), get new presigned URL, upload, and send. This is more secure and simpler.

**Files:**
- Create: `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBPendingPhotoUpload.swift`
- Modify: `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift`
- Create: `ConvosCore/Tests/ConvosCoreTests/PendingPhotoUploadTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
import GRDB
@testable import ConvosCore

@Suite("PendingPhotoUpload Tests")
struct PendingPhotoUploadTests {
    @Test("Can insert and fetch pending upload")
    func testInsertAndFetch() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.writer

        let upload = DBPendingPhotoUpload(
            id: "task-123",
            clientMessageId: "msg-456",
            conversationId: "conv-789",
            localCacheURL: "file:///cache/photo.jpg",
            state: .uploading,
            createdAt: Date(),
            updatedAt: Date()
        )

        try await writer.write { db in
            try upload.insert(db)
        }

        let fetched = try await writer.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        #expect(fetched?.clientMessageId == "msg-456")
        #expect(fetched?.state == .uploading)
    }

    @Test("Can update state to failed with error message")
    func testUpdateStateToFailed() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.writer

        let upload = DBPendingPhotoUpload(
            id: "task-123",
            clientMessageId: "msg-456",
            conversationId: "conv-789",
            localCacheURL: "file:///cache/photo.jpg",
            state: .uploading,
            createdAt: Date(),
            updatedAt: Date()
        )

        try await writer.write { db in
            try upload.insert(db)
        }

        try await writer.write { db in
            try DBPendingPhotoUpload
                .filter(key: "task-123")
                .updateAll(
                    db,
                    DBPendingPhotoUpload.Columns.state.set(to: PendingUploadState.failed.rawValue),
                    DBPendingPhotoUpload.Columns.errorMessage.set(to: "Network timeout")
                )
        }

        let fetched = try await writer.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: "task-123")
        }

        #expect(fetched?.state == .failed)
        #expect(fetched?.errorMessage == "Network timeout")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --package-path ConvosCore --filter PendingPhotoUploadTests`
Expected: FAIL - `DBPendingPhotoUpload` doesn't exist

**Step 3: Write minimal implementation**

Create `DBPendingPhotoUpload.swift`:

```swift
import Foundation
import GRDB

public enum PendingUploadState: String, Codable, DatabaseValueConvertible, Sendable {
    case uploading      // Background upload in progress
    case sending        // Upload done, XMTP send in progress
    case completed      // Fully done (can delete record)
    case failed         // Failed, user can retry
}

public struct DBPendingPhotoUpload: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "pendingPhotoUpload"

    public var id: String                    // Maps to URLSession task description
    public var clientMessageId: String       // Links to DBMessage
    public var conversationId: String
    public var localCacheURL: String         // Key to retrieve original image from ImageCacheContainer for retry
    public var state: PendingUploadState
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        clientMessageId: String,
        conversationId: String,
        localCacheURL: String,
        state: PendingUploadState,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.conversationId = conversationId
        self.localCacheURL = localCacheURL
        self.state = state
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let clientMessageId = Column(CodingKeys.clientMessageId)
        public static let conversationId = Column(CodingKeys.conversationId)
        public static let localCacheURL = Column(CodingKeys.localCacheURL)
        public static let state = Column(CodingKeys.state)
        public static let errorMessage = Column(CodingKeys.errorMessage)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }
}
```

Add migration to `SharedDatabaseMigrator.swift`:

```swift
migrator.registerMigration("createPendingPhotoUpload") { db in
    try db.create(table: "pendingPhotoUpload") { t in
        t.column("id", .text).primaryKey()
        t.column("clientMessageId", .text).notNull()
        t.column("conversationId", .text).notNull()
        t.column("localCacheURL", .text).notNull()
        t.column("state", .text).notNull()
        t.column("errorMessage", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
    }

    try db.create(index: "pendingPhotoUpload_state", on: "pendingPhotoUpload", columns: ["state"])
    try db.create(index: "pendingPhotoUpload_clientMessageId", on: "pendingPhotoUpload", columns: ["clientMessageId"])
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --package-path ConvosCore --filter PendingPhotoUploadTests`
Expected: PASS

**Step 5: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Storage/
git commit -m "feat: add DBPendingPhotoUpload model for upload state persistence"
```

---

## Task 3: Define BackgroundUploadManagerProtocol in ConvosCore

**Files:**
- Create: `ConvosCore/Sources/ConvosCore/Messaging/BackgroundUploadManagerProtocol.swift`

**Step 1: Write the protocol definition**

```swift
import Foundation

public struct BackgroundUploadResult: Sendable {
    public let taskId: String
    public let success: Bool
    public let error: Error?

    public init(taskId: String, success: Bool, error: Error? = nil) {
        self.taskId = taskId
        self.success = success
        self.error = error
    }
}

public protocol BackgroundUploadManagerProtocol: Sendable {
    /// Start a background upload task
    /// - Parameters:
    ///   - fileURL: URL to the file to upload (must be in persistent location, not temp)
    ///   - uploadURL: Presigned S3 URL
    ///   - contentType: MIME type
    ///   - taskId: Unique identifier for tracking (stored in URLSessionTask.taskDescription)
    /// - Returns: The task identifier
    func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws

    /// Cancel an in-progress upload
    func cancelUpload(taskId: String) async

    /// Called when app receives background URLSession events
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async

    /// Stream of upload completions (task ID, success/failure)
    var uploadCompletions: AsyncStream<BackgroundUploadResult> { get }
}
```

**Step 2: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Messaging/BackgroundUploadManagerProtocol.swift
git commit -m "feat: define BackgroundUploadManagerProtocol in ConvosCore"
```

---

## Task 4: Implement BackgroundUploadManager in ConvosCoreiOS

**Files:**
- Create: `ConvosCore/Sources/ConvosCoreiOS/BackgroundUploadManager.swift`

**Step 1: Write the implementation**

Note: Cannot use `actor` with `NSObject`. Use a class with careful synchronization.

```swift
import Foundation
import ConvosCore

public final class BackgroundUploadManager: NSObject, BackgroundUploadManagerProtocol, @unchecked Sendable {
    public static let shared = BackgroundUploadManager()

    public static let sessionIdentifier = "com.convos.backgroundUpload"

    private var backgroundSession: URLSession!
    private let lock = NSLock()

    // Task tracking
    private var taskCompletions: [String: CheckedContinuation<Void, Error>] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    // Stream for upload completions
    private var uploadCompletionsContinuation: AsyncStream<BackgroundUploadResult>.Continuation?
    public private(set) lazy var uploadCompletions: AsyncStream<BackgroundUploadResult> = {
        AsyncStream { continuation in
            self.uploadCompletionsContinuation = continuation
        }
    }()

    private override init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.shouldUseExtendedBackgroundIdleMode = true

        backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    public func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = taskId // Store taskId for later lookup
        task.resume()

        Log.info("Started background upload task \(task.taskIdentifier) for \(taskId)")
    }

    public func cancelUpload(taskId: String) async {
        backgroundSession.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskDescription == taskId }) {
                task.cancel()
                Log.info("Cancelled upload task \(taskId)")
            }
        }
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }

        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()

        Log.info("Handling background URLSession events for \(identifier)")
    }
}

extension BackgroundUploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let taskId = task.taskDescription else { return }

        let percentage = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        PhotoUploadProgressTracker.shared.setProgress(
            stage: .uploading,
            percentage: percentage,
            for: taskId
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let taskId = task.taskDescription else { return }

        let success: Bool
        if let error = error {
            Log.error("Background upload failed for \(taskId): \(error)")
            PhotoUploadProgressTracker.shared.setStage(.failed, for: taskId)
            success = false
        } else if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            Log.info("Background upload completed for \(taskId)")
            success = true
        } else {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error("Background upload failed with status \(statusCode) for \(taskId)")
            PhotoUploadProgressTracker.shared.setStage(.failed, for: taskId)
            success = false
        }

        // Emit completion event
        uploadCompletionsContinuation?.yield(BackgroundUploadResult(
            taskId: taskId,
            success: success,
            error: error
        ))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()

        if let handler = handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}
```

**Step 2: Commit**

```bash
git add ConvosCore/Sources/ConvosCoreiOS/BackgroundUploadManager.swift
git commit -m "feat: implement BackgroundUploadManager in ConvosCoreiOS"
```

---

## Task 5: Create PendingPhotoUploadWriter

**Files:**
- Create: `ConvosCore/Sources/ConvosCore/Storage/Writers/PendingPhotoUploadWriter.swift`

**Step 1: Write the writer**

```swift
import Foundation
import GRDB

public final class PendingPhotoUploadWriter: Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func create(_ upload: DBPendingPhotoUpload) async throws {
        try await databaseWriter.write { db in
            try upload.insert(db)
        }
    }

    public func updateState(
        taskId: String,
        state: PendingUploadState,
        errorMessage: String? = nil
    ) async throws {
        try await databaseWriter.write { db in
            try DBPendingPhotoUpload
                .filter(key: taskId)
                .updateAll(
                    db,
                    DBPendingPhotoUpload.Columns.state.set(to: state.rawValue),
                    DBPendingPhotoUpload.Columns.errorMessage.set(to: errorMessage),
                    DBPendingPhotoUpload.Columns.updatedAt.set(to: Date())
                )
        }
    }

    public func delete(taskId: String) async throws {
        try await databaseWriter.write { db in
            try DBPendingPhotoUpload.deleteOne(db, key: taskId)
        }
    }

    public func fetch(taskId: String) async throws -> DBPendingPhotoUpload? {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload.fetchOne(db, key: taskId)
        }
    }

    public func fetchPendingRetries() async throws -> [DBPendingPhotoUpload] {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.failed.rawValue)
                .fetchAll(db)
        }
    }

    public func fetchUploadsNeedingXMTPSend() async throws -> [DBPendingPhotoUpload] {
        try await databaseWriter.read { db in
            try DBPendingPhotoUpload
                .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.uploaded.rawValue)
                .fetchAll(db)
        }
    }
}
```

**Step 2: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Storage/Writers/PendingPhotoUploadWriter.swift
git commit -m "feat: add PendingPhotoUploadWriter for upload state management"
```

---

## Task 6: Update PhotoAttachmentService to Use Background Upload

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Messaging/PhotoAttachmentService.swift`
- Modify: `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

**Step 1: Add protocol method to ConvosAPIClientProtocol**

```swift
// In ConvosAPIClientProtocol, add:
func getPresignedUploadURL(
    filename: String,
    contentType: String
) async throws -> (uploadURL: String, assetURL: String)
```

**Step 2: Implement in ConvosAPIClient**

```swift
func getPresignedUploadURL(
    filename: String,
    contentType: String
) async throws -> (uploadURL: String, assetURL: String) {
    let request = try authenticatedRequest(
        for: "v2/attachments/presigned",
        method: "GET",
        queryParameters: ["contentType": contentType, "filename": filename]
    )

    struct PresignedResponse: Codable {
        let objectKey: String
        let uploadUrl: String
        let assetUrl: String
    }

    let response: PresignedResponse = try await performRequest(request)
    return (response.uploadUrl, response.assetUrl)
}
```

**Step 3: Update PhotoAttachmentService**

Add method to prepare for background upload:

```swift
public struct PreparedBackgroundUpload: Sendable {
    public let taskId: String
    public let encryptedFileURL: URL
    public let presignedUploadURL: URL
    public let assetURL: String
    public let encryptionSecret: Data
    public let encryptionSalt: Data
    public let encryptionNonce: Data
    public let contentDigest: String
    public let filename: String
}

public func prepareForBackgroundUpload(
    image: ImageType,
    apiClient: any ConvosAPIClientProtocol,
    filename: String
) async throws -> PreparedBackgroundUpload {
    // Compress image
    guard let compressedData = ImageCompression.compressForPhotoAttachment(image) else {
        throw PhotoAttachmentError.compressionFailed
    }

    // Encrypt with XMTP
    let attachment = Attachment(filename: filename, mimeType: "image/jpeg", data: compressedData)
    let encrypted = try RemoteAttachment.encodeEncrypted(content: attachment, codec: AttachmentCodec())

    // Get presigned URL
    let (uploadURL, assetURL) = try await apiClient.getPresignedUploadURL(
        filename: filename,
        contentType: "application/octet-stream"
    )

    guard let presignedURL = URL(string: uploadURL) else {
        throw PhotoAttachmentError.invalidURL
    }

    // Save encrypted payload to persistent location (not temp!)
    let taskId = UUID().uuidString
    let uploadsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PendingUploads", isDirectory: true)
    try FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)

    let encryptedFileURL = uploadsDir.appendingPathComponent("\(taskId).enc")
    try encrypted.payload.write(to: encryptedFileURL)

    return PreparedBackgroundUpload(
        taskId: taskId,
        encryptedFileURL: encryptedFileURL,
        presignedUploadURL: presignedURL,
        assetURL: assetURL,
        encryptionSecret: encrypted.secret,
        encryptionSalt: encrypted.salt,
        encryptionNonce: encrypted.nonce,
        contentDigest: encrypted.digest,
        filename: filename
    )
}
```

**Step 4: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/
git commit -m "feat: add prepareForBackgroundUpload to PhotoAttachmentService"
```

---

## Task 7: Update OutgoingMessageWriter to Use Background Upload + Eager Upload

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Storage/Writers/OutgoingMessageWriter.swift`
- Modify: `Convos/Conversation Detail/ConversationViewModel.swift`
- Modify: `Convos/Conversation Detail/ConversationView.swift`

### Part A: Add Eager Upload Protocol Methods

Add these methods to `OutgoingMessageWriterProtocol`:

```swift
/// Start uploading a photo immediately when selected (before Send is tapped)
func startEagerUpload(image: ImageType) async throws -> String

/// Send a photo that was already uploaded via eager upload
func sendEagerPhoto(trackingKey: String) async throws

/// Cancel an in-progress eager upload (when user removes the photo)
func cancelEagerUpload(trackingKey: String) async
```

Implementation stores upload state in `eagerUploads: [String: EagerUploadState]` dictionary, keyed by tracking key.

### Part B: Wire Up ConversationViewModel

```swift
// Track the current eager upload
private(set) var currentEagerUploadKey: String?

func onPhotoSelected(_ image: UIImage) {
    Task {
        let trackingKey = try await messageWriter.startEagerUpload(image: image)
        await MainActor.run { currentEagerUploadKey = trackingKey }
    }
}

func onPhotoRemoved() {
    guard let trackingKey = currentEagerUploadKey else { return }
    currentEagerUploadKey = nil
    Task { await messageWriter.cancelEagerUpload(trackingKey: trackingKey) }
}
```

### Part C: Trigger from ConversationView

```swift
.onChange(of: viewModel.selectedAttachmentImage) { oldValue, newValue in
    if let image = newValue {
        viewModel.onPhotoSelected(image)
    } else if oldValue != nil {
        viewModel.onPhotoRemoved()
    }
}
```

### Part D: Update onSendMessage to use eager upload

**Step 1: Update publishPhoto to use background upload**

Replace the synchronous upload with:

```swift
private func publishPhoto(_ queued: QueuedPhotoMessage) async throws {
    let trackingKey = queued.localCacheURL.absoluteString
    let tracker = PhotoUploadProgressTracker.shared

    tracker.setStage(.preparing, for: trackingKey)

    let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

    // Prepare for background upload
    let prepared: PreparedBackgroundUpload
    do {
        prepared = try await photoService.prepareForBackgroundUpload(
            image: queued.image,
            apiClient: inboxReady.apiClient,
            filename: queued.filename
        )
    } catch {
        tracker.setStage(.failed, for: trackingKey)
        try? await markMessageFailed(clientMessageId: queued.clientMessageId)
        throw error
    }

    // Persist upload state for crash recovery
    let pendingUpload = DBPendingPhotoUpload(
        id: prepared.taskId,
        clientMessageId: queued.clientMessageId,
        conversationId: conversationId,
        localFilePath: prepared.encryptedFileURL.path,
        presignedUploadURL: prepared.presignedUploadURL.absoluteString,
        assetURL: prepared.assetURL,
        encryptionSecret: prepared.encryptionSecret,
        encryptionSalt: prepared.encryptionSalt,
        encryptionNonce: prepared.encryptionNonce,
        contentDigest: prepared.contentDigest,
        filename: prepared.filename,
        state: .uploading
    )
    try await pendingUploadWriter.create(pendingUpload)

    // Start background upload
    tracker.setProgress(stage: .uploading, percentage: 0, for: trackingKey)

    try await backgroundUploadManager.startUpload(
        fileURL: prepared.encryptedFileURL,
        uploadURL: prepared.presignedUploadURL,
        contentType: "application/octet-stream",
        taskId: prepared.taskId
    )

    // Listen for completion (will also fire if app was backgrounded and upload completed)
    for await result in backgroundUploadManager.uploadCompletions {
        guard result.taskId == prepared.taskId else { continue }

        if result.success {
            try await pendingUploadWriter.updateState(taskId: prepared.taskId, state: .uploaded)
            break
        } else {
            tracker.setStage(.failed, for: trackingKey)
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: result.error?.localizedDescription
            )
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw result.error ?? PhotoAttachmentError.uploadFailed("Unknown error")
        }
    }

    // Continue with XMTP send (same as before)
    tracker.setStage(.publishing, for: trackingKey)
    try await completeXMTPSend(pendingUpload: pendingUpload, trackingKey: trackingKey)
}

private func completeXMTPSend(pendingUpload: DBPendingPhotoUpload, trackingKey: String) async throws {
    // ... existing XMTP send logic using pendingUpload fields ...
    // On success: delete pendingUpload record
    // On failure: update state to .failed (user can retry)
}
```

**Step 2: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Storage/Writers/OutgoingMessageWriter.swift
git commit -m "feat: use background upload in OutgoingMessageWriter"
```

---

## Task 8: Wire Up AppDelegate for Background URLSession Events

**Files:**
- Modify: `Convos/AppDelegate.swift` (or SceneDelegate)

**Step 1: Add handler**

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    Task {
        await BackgroundUploadManager.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
```

**Step 2: Commit**

```bash
git add Convos/
git commit -m "feat: handle background URLSession events in AppDelegate"
```

---

## Task 9: Add Retry UI for Failed Uploads

**Files:**
- Modify: Message cell view to show retry button for failed messages

**Step 1: Update message status display**

When a message has `status == .failed` and there's a corresponding `DBPendingPhotoUpload` with `state == .failed`:
- Show "Retry" button
- On tap, call a retry method that restarts the upload from the persisted state

**Step 2: Implement retry logic**

```swift
func retryFailedUpload(pendingUpload: DBPendingPhotoUpload) async throws {
    guard pendingUpload.state == .failed else { return }

    // Check if encrypted file still exists
    let fileURL = URL(fileURLWithPath: pendingUpload.localFilePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        // File was cleaned up, need to re-prepare
        throw PhotoAttachmentError.localSaveFailed
    }

    // Restart background upload
    try await pendingUploadWriter.updateState(taskId: pendingUpload.id, state: .uploading)

    guard let uploadURL = URL(string: pendingUpload.presignedUploadURL) else {
        throw PhotoAttachmentError.invalidURL
    }

    try await backgroundUploadManager.startUpload(
        fileURL: fileURL,
        uploadURL: uploadURL,
        contentType: "application/octet-stream",
        taskId: pendingUpload.id
    )
}
```

**Step 3: Commit**

```bash
git add Convos/
git commit -m "feat: add retry UI and logic for failed photo uploads"
```

---

## Testing Checklist

### Eager Upload
- [ ] Select photo from picker → upload starts immediately (see "Started background upload task" log)
- [ ] Remove photo before sending → upload is cancelled
- [ ] Select photo, wait for upload to complete, tap Send → message sends immediately
- [ ] Select photo, tap Send before upload completes → waits for upload, then sends

### Multiple Concurrent Uploads
- [ ] Select Photo A → tap Send → select Photo B → tap Send → both photos send successfully
- [ ] Select Photo A → tap Send (while A uploading) → select Photo B → tap Send (while B uploading) → both complete
- [ ] Order of message delivery matches upload completion order (first to finish uploading sends first)
- [ ] Select Photo A → tap Send → select Photo B → Photo A's upload continues (was committed)
- [ ] Select Photo A → select Photo B (no Send) → Photo A's upload is cancelled (user changed mind)

### Background Upload
- [ ] Upload a photo and see percentage progress (0% → 100%)
- [ ] Background app during upload → upload continues
- [ ] Terminate app during upload → on relaunch, can retry failed upload
- [ ] Upload completes in background → XMTP send completes (or surfaces retry)
- [ ] Large photo (~5MB) shows smooth progress

### Retry (Task 9 - SKIPPED)
- [ ] Failed upload shows "Retry" button in message cell
- [ ] Retry button restarts the upload successfully

---

## Files Changed Summary

| File | Change Type | Purpose |
|------|-------------|---------|
| `PhotoUploadProgressTracker.swift` | Modified | Add percentage tracking |
| `DBPendingPhotoUpload.swift` | Created | Persist upload state |
| `SharedDatabaseMigrator.swift` | Modified | Add migration |
| `BackgroundUploadManagerProtocol.swift` | Created | Protocol in ConvosCore |
| `BackgroundUploadManager.swift` | Created (ConvosCoreiOS) | iOS implementation |
| `PendingPhotoUploadWriter.swift` | Created | Database operations |
| `PhotoAttachmentService.swift` | Modified | Background upload prep |
| `ConvosAPIClient.swift` | Modified | Presigned URL method |
| `OutgoingMessageWriter.swift` | Modified | Use background upload + eager upload methods |
| `ConversationViewModel.swift` | Modified | Trigger eager upload on photo selection |
| `ConversationView.swift` | Modified | `.onChange` to detect photo selection |
| `MockOutgoingMessageWriter.swift` | Modified | Add eager upload stub methods |
| `MockConversationStateManager.swift` | Modified | Add eager upload stub methods |
| `ConversationStateManager.swift` | Modified | Add eager upload stub methods |
| `AppDelegate.swift` | Modified | Handle background events |
| Message cell view | Skipped | Retry UI (Task 9 skipped) |

---

## Future Enhancements (Separate Plans)

1. **Push notification photo prefetching** (Use Case 3) - Download photos in Notification Service Extension
2. **Automatic retry with exponential backoff** - Retry failed uploads automatically with backoff
3. **Upload queue management** - Handle multiple concurrent uploads with priority
4. **Network reachability awareness** - Pause uploads when offline
5. **Live Activities** - Show upload progress on lock screen
