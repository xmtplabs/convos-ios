import Foundation

public enum AccountDeletionStateStoreError: Error, Equatable {
    case invalidTransition(from: AccountDeletionPhase, to: AccountDeletionPhase)
    /// A record already exists for a different operation; a second deletion
    /// cannot begin until the first completes or is cleared.
    case recordAlreadyExists(existingOperationId: UUID)
}

/// Thrown when identity provisioning is refused because an account-deletion
/// record is active (any non-completed phase, or a corrupt record whose
/// phase is unknowable). Not a `TerminalSessionError`: the condition clears
/// when the wipe completes or the pending deletion is resolved.
public struct AccountDeletionInProgressError: Error, Equatable {
    public init() {}
}

/// Result of reading the durable deletion record.
public enum AccountDeletionLoadResult: Sendable {
    /// No deletion is in flight.
    case none
    /// A deletion is in flight in the record's phase.
    case record(AccountDeletionRecord)
    /// A file exists but cannot be decoded. Callers must fail safe: hold
    /// identity provisioning (as if a record were active) and surface a
    /// recovery affordance, never silently discard the file.
    case corrupted

    public var activeRecord: AccountDeletionRecord? {
        if case .record(let record) = self { return record }
        return nil
    }

    /// True whenever startup must hold identity auto-provisioning: any
    /// present record, or a corrupt file whose phase is unknowable.
    public var blocksIdentityProvisioning: Bool {
        switch self {
        case .none: return false
        case .record, .corrupted: return true
        }
    }
}

/// File-backed durable store for the account-deletion record.
///
/// The record lives as JSON in the app-group container (not GRDB: the wipe
/// empties the database and DatabaseManager init runs LegacyDataWipe; not
/// UserDefaults: flush timing is less deterministic under crash). Writes are
/// atomic (temp file + rename), so readers observe either the previous or the
/// new record, never a torn write. The actor serializes writers; reads are
/// `nonisolated` so launch-path code that cannot suspend (the provisioning
/// gate inside `SessionManager.loadOrCreateService`) can consult the store
/// synchronously.
public actor AccountDeletionStateStore {
    private let fileURL: URL

    /// - Parameter directoryURL: directory the record file lives in; the
    ///   app passes the app-group container so the record survives
    ///   everything short of app removal. Tests pass a temp directory.
    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent(Constant.fileName, isDirectory: false)
    }

    /// Store rooted in the environment's shared container (the same
    /// directory the databases live in).
    public init(environment: AppEnvironment) {
        self.init(directoryURL: environment.defaultDatabasesDirectoryURL)
    }

    // MARK: - Reads

    public nonisolated func load() -> AccountDeletionLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return .none
            }
            Log.error("AccountDeletionStateStore: unreadable record file (\(error)); failing safe as corrupted")
            return .corrupted
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(AccountDeletionRecord.self, from: data)
            return .record(record)
        } catch {
            Log.error("AccountDeletionStateStore: undecodable record file (\(error)); failing safe as corrupted")
            return .corrupted
        }
    }

    // MARK: - Writes

    /// Writes the initial `requested` record. Fails if a different deletion
    /// is already recorded (idempotent for the same operation id).
    public func begin(_ record: AccountDeletionRecord) throws {
        switch load() {
        case .none, .corrupted:
            // A corrupt file is replaced by an explicit new deletion: the
            // user re-confirmed intent, and the fresh record restores a
            // known phase for recovery.
            break
        case .record(let existing):
            guard existing.operationId == record.operationId else {
                throw AccountDeletionStateStoreError.recordAlreadyExists(existingOperationId: existing.operationId)
            }
        }
        try write(record)
    }

    /// Advances the persisted record to `phase` and returns the new record.
    /// Transition legality is validated against the record on disk.
    @discardableResult
    public func advance(
        to phase: AccountDeletionPhase,
        at date: Date = Date(),
        purgeWindowHours: Int? = nil
    ) throws -> AccountDeletionRecord {
        guard let current = load().activeRecord else {
            throw AccountDeletionStateStoreError.invalidTransition(from: .requested, to: phase)
        }
        let advanced = try current.advanced(to: phase, at: date, purgeWindowHours: purgeWindowHours)
        try write(advanced)
        return advanced
    }

    /// Marks the current record preflight-aborted: the deletion request
    /// was provably never sent and the record could not be cleared. Launch
    /// recovery retries only the cleanup for such a record and never
    /// re-sends the deletion. A no-op when no record is loadable.
    public func markPreflightAborted() throws {
        guard let current = load().activeRecord else { return }
        try write(current.markedPreflightAborted())
    }

    /// Marks the current record send-attempted, in one atomic record
    /// write. The deletion flow persists this before the request goes out;
    /// launch recovery auto-resends only marked records. A no-op when no
    /// record is loadable.
    public func markSendAttempted() throws {
        guard let current = load().activeRecord else { return }
        try write(current.markedSendAttempted())
    }

    /// Clears the record; the `completed` transition and the final act of
    /// the wipe. Idempotent.
    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError {
                return
            }
            throw error
        }
    }

    // MARK: - Private

    private func write(_ record: AccountDeletionRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: [.atomic])
    }

    private enum Constant {
        static let fileName: String = "account-deletion-record.json"
    }
}
