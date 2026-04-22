import Foundation

/// Tar format + pack/unpack for the iCloud backup bundle.
///
/// Format:
///
///     [4-byte magic "CVBD"]
///     [1-byte format version]
///     [entries...]
///
/// Each entry:
///
///     [4-byte path length BE][path UTF8][8-byte file length BE][file data]
///
/// The magic + version header lets future bundle-format bumps
/// discriminate cleanly rather than decoding past-incompatible data.
/// The entry format is a straight port of the old single-file-at-a-time
/// layout; hardened against path-traversal on unpack via both a
/// standardized-path check and a symlink-resolved re-check after
/// `createDirectory`.
public enum BackupBundle {
    enum BundleError: Error, LocalizedError {
        case directoryCreationFailed(String)
        case packagingFailed(String)
        case unpackingFailed(String)
        case missingComponent(String)
        case invalidMagic(expected: String, got: String)
        case unsupportedVersion(got: UInt8, supported: UInt8)

        var errorDescription: String? {
            switch self {
            case let .directoryCreationFailed(reason):
                return "Failed to create backup directory: \(reason)"
            case let .packagingFailed(reason):
                return "Failed to package backup bundle: \(reason)"
            case let .unpackingFailed(reason):
                return "Failed to unpack backup bundle: \(reason)"
            case let .missingComponent(name):
                return "Missing backup component: \(name)"
            case let .invalidMagic(expected, got):
                return "Not a Convos backup bundle (expected magic \(expected), got \(got))"
            case let .unsupportedVersion(got, supported):
                return "Backup bundle format v\(got) is not supported (this build supports v\(supported))"
            }
        }
    }

    /// ASCII "CVBD" — Convos Backup Data.
    static let magic: [UInt8] = [0x43, 0x56, 0x42, 0x44]

    /// Current on-disk format version. Bump when a backwards-incompatible
    /// structural change lands (e.g. media blobs, compressed entries).
    static let currentFormatVersion: UInt8 = 1

    public enum Component {
        /// Must match `DatabaseManager.databaseFilename` — the live DB
        /// file is handed to the bundle unchanged, then read back
        /// under the same name by `RestoreManager.replaceDatabase`.
        public static let database: String = DatabaseManager.databaseFilename
        public static let xmtpArchive: String = "xmtp-archive.bin"
        public static let metadata: String = "metadata.json"
    }

    // MARK: - Staging

    public static func createStagingDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw BundleError.directoryCreationFailed(error.localizedDescription)
        }
        return tempDir
    }

    public static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    public static func databasePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Component.database)
    }

    public static func xmtpArchivePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Component.xmtpArchive)
    }

    // MARK: - Pack / unpack

    public static func pack(directory: URL, encryptionKey: Data) throws -> Data {
        let tarData = try tarDirectory(directory)
        return try BackupBundleCrypto.encrypt(data: tarData, key: encryptionKey)
    }

    public static func unpack(data: Data, encryptionKey: Data, to directory: URL) throws {
        let tarData = try BackupBundleCrypto.decrypt(data: data, key: encryptionKey)
        try untarData(tarData, to: directory)
    }

    // MARK: - Tar (internal)

    static func tarDirectory(_ directory: URL) throws -> Data {
        var archive = Data()
        archive.append(contentsOf: magic)
        archive.append(currentFormatVersion)

        let fileManager = FileManager.default
        let resolvedDirPath = resolvedPath(directory)
        let resolvedDirURL = URL(fileURLWithPath: resolvedDirPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: resolvedDirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BundleError.packagingFailed("failed to enumerate directory")
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let resolvedFilePath = resolvedPath(fileURL)
            guard resolvedFilePath.hasPrefix(resolvedDirPath + "/") else {
                throw BundleError.packagingFailed("file outside backup directory: \(fileURL.path)")
            }
            let relativePath = String(resolvedFilePath.dropFirst(resolvedDirPath.count + 1))
            let pathData = Data(relativePath.utf8)
            let fileData = try Data(contentsOf: fileURL)

            var pathLength = UInt32(pathData.count).bigEndian
            var fileLength = UInt64(fileData.count).bigEndian
            archive.append(Data(bytes: &pathLength, count: 4))
            archive.append(pathData)
            archive.append(Data(bytes: &fileLength, count: 8))
            archive.append(fileData)
        }

        return archive
    }

    static func untarData(_ data: Data, to directory: URL) throws {
        let fileManager = FileManager.default
        let resolvedDirPath = resolvedPath(directory)
        var offset = 0

        try validateHeader(data, offset: &offset)

        while offset < data.count {
            guard offset + 4 <= data.count else {
                throw BundleError.unpackingFailed("truncated path length")
            }
            let pathLength = Int(data
                .subdata(in: offset ..< offset + 4)
                .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            offset += 4

            // A zero-length path would decode to the empty string and
            // resolve via `appendingPathComponent("")` to the staging
            // directory URL itself — the containment check would reject
            // it for not having the trailing-slash prefix, but costs
            // nothing to bail early with a clearer error.
            guard pathLength > 0 else {
                throw BundleError.unpackingFailed("empty entry path")
            }

            guard offset + pathLength <= data.count else {
                throw BundleError.unpackingFailed("truncated path data")
            }
            guard let relativePath = String(
                data: data.subdata(in: offset ..< offset + pathLength),
                encoding: .utf8
            ) else {
                throw BundleError.unpackingFailed("invalid path encoding")
            }
            offset += pathLength

            guard offset + 8 <= data.count else {
                throw BundleError.unpackingFailed("truncated file length")
            }
            let fileLengthU64 = data.subdata(in: offset ..< offset + 8)
                .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            guard fileLengthU64 <= UInt64(Int.max) else {
                throw BundleError.unpackingFailed("file length exceeds maximum: \(fileLengthU64)")
            }
            let fileLength = Int(fileLengthU64)
            offset += 8

            guard offset + fileLength <= data.count else {
                throw BundleError.unpackingFailed("truncated file data")
            }
            let fileData = data.subdata(in: offset ..< offset + fileLength)
            offset += fileLength

            let resolvedFileURL = URL(fileURLWithPath: resolvedDirPath)
                .appendingPathComponent(relativePath)

            // First-pass containment check on the standardized path.
            let standardizedPath = resolvedFileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(resolvedDirPath + "/") else {
                throw BundleError.unpackingFailed("path traversal attempt: \(relativePath)")
            }

            // Create the parent directory, then re-validate using the
            // symlink-resolved path of the parent. `fileData.write(to:)`
            // follows symlinks when writing, so a pre-existing symlink
            // under the staging dir could escape the first-pass check.
            // Re-resolving the parent after createDirectory catches that.
            let parentDir = resolvedFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let resolvedParentPath = parentDir.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolvedParentPath == resolvedDirPath
                || resolvedParentPath.hasPrefix(resolvedDirPath + "/") else {
                throw BundleError.unpackingFailed("path traversal via symlink: \(relativePath)")
            }

            try fileData.write(to: resolvedFileURL)
        }
    }

    private static func validateHeader(_ data: Data, offset: inout Int) throws {
        guard data.count >= magic.count + 1 else {
            throw BundleError.unpackingFailed("bundle too short to contain header")
        }
        let magicBytes = Array(data[offset ..< offset + magic.count])
        guard magicBytes == magic else {
            let expected = String(bytes: magic, encoding: .ascii) ?? "CVBD"
            let got = String(bytes: magicBytes, encoding: .ascii) ?? "<invalid>"
            throw BundleError.invalidMagic(expected: expected, got: got)
        }
        offset += magic.count

        let version = data[offset]
        guard version == currentFormatVersion else {
            throw BundleError.unsupportedVersion(got: version, supported: currentFormatVersion)
        }
        offset += 1
    }

    private static func resolvedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
