import Foundation

/// Backup bundle packaging: staging directory layout, tar format, path-traversal
/// hardening, and the `CVBD` magic + format-version byte prepended to every tar.
///
/// The bundle carries exactly three files inside the tar:
/// - `convos-single-inbox.sqlite` — a GRDB snapshot of the user's local DB
/// - `xmtp-archive.bin` — a single-inbox XMTP `createArchive` output
/// - `metadata.json` — the inner metadata (carries `archiveKey`)
///
/// Every tar is prepended with a 5-byte header (`"CVBD"` + 1-byte version) and
/// then sealed with AES-GCM under the identity's `databaseKey`. Unsealed bytes
/// always start with the header, so a missing or mismatched header is treated
/// as corruption before any parsing happens.
public enum BackupBundle {
    enum BundleError: Error, LocalizedError {
        case directoryCreationFailed(String)
        case databaseCopyFailed(String)
        case packagingFailed(String)
        case unpackingFailed(String)
        case missingComponent(String)
        case invalidMagic
        case unsupportedFormatVersion(UInt8)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let reason):
                return "Failed to create backup directory: \(reason)"
            case .databaseCopyFailed(let reason):
                return "Failed to copy database: \(reason)"
            case .packagingFailed(let reason):
                return "Failed to package backup bundle: \(reason)"
            case .unpackingFailed(let reason):
                return "Failed to unpack backup bundle: \(reason)"
            case .missingComponent(let name):
                return "Missing backup component: \(name)"
            case .invalidMagic:
                return "Bundle header is not a Convos backup"
            case .unsupportedFormatVersion(let version):
                return "Bundle format version \(version) is not supported"
            }
        }
    }

    /// 4-byte magic prefix (`"CVBD"`). Lets readers reject a file that is not a
    /// Convos backup before attempting to parse any length fields.
    static let magicBytes: Data = Data("CVBD".utf8)

    /// Current format version. Bump when the tar layout changes incompatibly.
    /// Readers MUST compare against `supportedFormatVersions`.
    static let currentFormatVersion: UInt8 = 1

    /// Versions this build can read. `currentFormatVersion` is always included.
    static let supportedFormatVersions: Set<UInt8> = [1]

    /// Total header size: 4-byte magic + 1-byte version.
    private static let headerLength: Int = 5

    private enum Constant {
        static let databaseFilename: String = "convos-single-inbox.sqlite"
        static let archiveFilename: String = "xmtp-archive.bin"
    }

    // MARK: - Paths

    static func createStagingDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw BundleError.directoryCreationFailed(error.localizedDescription)
        }
        return tempDir
    }

    public static func databasePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Constant.databaseFilename)
    }

    public static func archivePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Constant.archiveFilename)
    }

    static func copyDatabase(from sourcePath: URL, to directory: URL) throws {
        let destination = databasePath(in: directory)
        do {
            try FileManager.default.copyItem(at: sourcePath, to: destination)
        } catch {
            throw BundleError.databaseCopyFailed(error.localizedDescription)
        }
    }

    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pack / unpack

    /// Tars `directory`, prepends the header, and AES-GCM seals the result.
    static func pack(directory: URL, encryptionKey: Data) throws -> Data {
        let tarData = try tarDirectory(directory)
        var framed = Data(capacity: headerLength + tarData.count)
        framed.append(magicBytes)
        framed.append(currentFormatVersion)
        framed.append(tarData)
        return try BackupBundleCrypto.encrypt(data: framed, key: encryptionKey)
    }

    /// Opens the AES-GCM seal, validates the header, then untars the body into
    /// `directory`. Rejects any file whose resolved path escapes `directory`.
    static func unpack(data: Data, encryptionKey: Data, to directory: URL) throws {
        let framed = try BackupBundleCrypto.decrypt(data: data, key: encryptionKey)
        guard framed.count >= headerLength else {
            throw BundleError.unpackingFailed("bundle shorter than header")
        }
        let magic = framed.prefix(magicBytes.count)
        guard magic == magicBytes else {
            throw BundleError.invalidMagic
        }
        let version = framed[framed.startIndex + magicBytes.count]
        guard supportedFormatVersions.contains(version) else {
            throw BundleError.unsupportedFormatVersion(version)
        }
        let tarData = framed.suffix(from: framed.startIndex + headerLength)
        try untarData(Data(tarData), to: directory)
    }

    // MARK: - Tar format: [4-byte path length][path UTF8][8-byte file length][file data]...

    private static func resolvedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func tarDirectory(_ directory: URL) throws -> Data {
        var archive = Data()
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

        while offset < data.count {
            guard offset + 4 <= data.count else {
                throw BundleError.unpackingFailed("truncated path length")
            }
            let pathLength = Int(data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            offset += 4

            guard offset + pathLength <= data.count else {
                throw BundleError.unpackingFailed("truncated path data")
            }
            guard let relativePath = String(data: data.subdata(in: offset ..< offset + pathLength), encoding: .utf8) else {
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

            let standardizedPath = resolvedFileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(resolvedDirPath + "/") else {
                throw BundleError.unpackingFailed("path traversal attempt: \(relativePath)")
            }

            // fileData.write(to:) follows symlinks when writing, so a pre-existing
            // symlink under the staging dir could escape the first-pass check.
            // Re-resolve the parent after creating it and re-check.
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
}
