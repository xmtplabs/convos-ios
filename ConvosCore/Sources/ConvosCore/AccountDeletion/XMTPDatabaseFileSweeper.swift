import Foundation

/// Thrown when a file sweep left artifacts behind; the failed paths are
/// carried for logging. The account-deletion manifest treats this as an
/// entry failure so the durable record survives and the next launch
/// retries.
struct FileSweepIncompleteError: Error {
    let failedPaths: [String]
}

/// Deletes libxmtp's on-disk database files.
///
/// XMTPiOS names its SQLite files `xmtp-<gRPC-host>-<hash>.db3` with
/// `-wal`/`-shm`/`.sqlcipher_salt` sidecars. Under single-inbox there is one
/// `xmtp-*` family per install, so removing every `xmtp-`-prefixed file in
/// the databases directory is the correct scope. Idempotent; used by both
/// the session delete path (best-effort) and the account-deletion wipe
/// manifest (throwing, so failures propagate and retry).
enum XMTPDatabaseFileSweeper {
    /// Removes every `xmtp-*` file in `directory`. A missing directory is a
    /// no-op; a failed removal throws with the surviving paths.
    static func sweep(directory: URL) throws {
        try removeEntries(in: directory, kind: "XMTP database") { url in
            url.lastPathComponent.hasPrefix("xmtp-")
        }
    }

    /// Removes every entry inside `directory` (used for the XMTP log
    /// directory, whose files carry inbox identifiers). A missing directory
    /// is a no-op; a failed removal throws with the surviving paths.
    static func sweepContents(of directory: URL) throws {
        try removeEntries(in: directory, kind: "log") { _ in true }
    }

    private static func removeEntries(
        in directory: URL,
        kind: String,
        matching predicate: (URL) -> Bool
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var failedPaths: [String] = []
        for url in entries where predicate(url) {
            do {
                try fileManager.removeItem(at: url)
                Log.debug("Deleted \(kind) file: \(url.lastPathComponent)")
            } catch {
                Log.error("Failed to delete \(kind) file \(url.lastPathComponent): \(error)")
                failedPaths.append(url.lastPathComponent)
            }
        }
        if !failedPaths.isEmpty {
            throw FileSweepIncompleteError(failedPaths: failedPaths)
        }
    }
}
