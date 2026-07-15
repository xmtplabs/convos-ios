import Foundation

/// Deletes libxmtp's on-disk database files.
///
/// XMTPiOS names its SQLite files `xmtp-<gRPC-host>-<hash>.db3` with
/// `-wal`/`-shm`/`.sqlcipher_salt` sidecars. Under single-inbox there is one
/// `xmtp-*` family per install, so removing every `xmtp-`-prefixed file in
/// the databases directory is the correct scope. Idempotent; used by both
/// the session delete path and the account-deletion wipe manifest.
enum XMTPDatabaseFileSweeper {
    static func sweep(directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in entries where url.lastPathComponent.hasPrefix("xmtp-") {
            do {
                try fileManager.removeItem(at: url)
                Log.debug("Deleted XMTP database file: \(url.lastPathComponent)")
            } catch {
                Log.error("Failed to delete XMTP database file \(url.lastPathComponent): \(error)")
            }
        }
    }
}
