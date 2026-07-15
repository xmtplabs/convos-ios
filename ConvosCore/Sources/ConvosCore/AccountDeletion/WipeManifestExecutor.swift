import Foundation

/// One idempotent teardown step, keyed by a `WipeManifestEntry`.
public struct WipeStep: Sendable {
    private let body: @Sendable (AccountDeletionRecord) async throws -> Void

    public init(_ body: @escaping @Sendable (AccountDeletionRecord) async throws -> Void) {
        self.body = body
    }

    public func run(record: AccountDeletionRecord) async throws {
        try await body(record)
    }
}

/// Outcome of one manifest run. The wipe is complete (and the deletion
/// record may be cleared) only when `isComplete` is true; otherwise the
/// record stays in `localWipePending` and the next launch re-runs the whole
/// manifest (entries are idempotent, so no per-entry cursor is needed).
public struct WipeManifestRunResult: Sendable {
    public let executed: [WipeManifestEntry]
    public let failures: [WipeManifestFailure]

    public var isComplete: Bool { failures.isEmpty }
}

public struct WipeManifestFailure: Sendable {
    public let entry: WipeManifestEntry
    public let error: any Error
}

public struct WipeManifestIncompleteError: Error, Sendable {
    public let failures: [WipeManifestFailure]
}

/// Runs the wipe manifest for a deletion record. Handlers are injected per
/// entry: ConvosCore wires the entries it owns, and the app target injects
/// hooks for state that lives above ConvosCore (analytics reset, UI
/// defaults).
///
/// Execution never short-circuits: a failing entry is recorded and the run
/// continues, so one stuck subsystem cannot shield the rest of the identity
/// footprint from teardown. A missing handler for a manifest entry counts as
/// a failure - silently skipping an inventoried entry would break the
/// "reinstall equals first install" guarantee.
public struct WipeManifestExecutor: Sendable {
    private let handlers: [WipeManifestEntry: WipeStep]

    public init(handlers: [WipeManifestEntry: WipeStep]) {
        self.handlers = handlers
    }

    public func run(record: AccountDeletionRecord) async -> WipeManifestRunResult {
        var executed: [WipeManifestEntry] = []
        var failures: [WipeManifestFailure] = []
        for entry in WipeManifest.entries(forVersion: record.wipeManifestVersion) {
            guard let step = handlers[entry] else {
                Log.error("Wipe manifest entry \(entry.rawValue) has no handler")
                failures.append(WipeManifestFailure(entry: entry, error: WipeManifestExecutorError.missingHandler(entry)))
                continue
            }
            do {
                try await step.run(record: record)
                executed.append(entry)
            } catch {
                Log.error("Wipe manifest entry \(entry.rawValue) failed: \(error)")
                failures.append(WipeManifestFailure(entry: entry, error: error))
            }
        }
        return WipeManifestRunResult(executed: executed, failures: failures)
    }
}

public enum WipeManifestExecutorError: Error, Equatable {
    case missingHandler(WipeManifestEntry)
}
