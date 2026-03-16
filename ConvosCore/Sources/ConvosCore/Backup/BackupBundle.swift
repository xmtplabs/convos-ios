import Foundation

public enum BackupBundle {
    enum BundleError: Error, LocalizedError {
        case directoryCreationFailed(String)
        case databaseCopyFailed(String)
        case packagingFailed(String)
        case unpackingFailed(String)
        case missingComponent(String)

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
            }
        }
    }

    private enum Constant {
        static let vaultArchiveFilename: String = "vault-archive.encrypted"
        static let conversationsDirectory: String = "conversations"
        static let databaseFilename: String = "database.sqlite"
    }

    static func createStagingDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(Constant.conversationsDirectory, isDirectory: true),
            withIntermediateDirectories: true
        )
        return tempDir
    }

    static func vaultArchivePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Constant.vaultArchiveFilename)
    }

    static func conversationArchivePath(inboxId: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(Constant.conversationsDirectory, isDirectory: true)
            .appendingPathComponent("\(inboxId).encrypted")
    }

    static func databasePath(in directory: URL) -> URL {
        directory.appendingPathComponent(Constant.databaseFilename)
    }

    static func copyDatabase(from sourcePath: URL, to directory: URL) throws {
        let destination = databasePath(in: directory)
        do {
            try FileManager.default.copyItem(at: sourcePath, to: destination)
        } catch {
            throw BundleError.databaseCopyFailed(error.localizedDescription)
        }
    }

    static func pack(directory: URL, encryptionKey: Data) throws -> Data {
        let tarData = try tarDirectory(directory)
        return try BackupBundleCrypto.encrypt(data: tarData, key: encryptionKey)
    }

    static func unpack(data: Data, encryptionKey: Data, to directory: URL) throws {
        let tarData = try BackupBundleCrypto.decrypt(data: data, key: encryptionKey)
        try untarData(tarData, to: directory)
    }

    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Tar archive (simple concatenation format)

    static func tarDirectory(_ directory: URL) throws -> Data {
        var archive = Data()
        let fileManager = FileManager.default
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BundleError.packagingFailed("failed to enumerate directory")
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }

            let resolvedFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            let relativePath = resolvedFile.path.replacingOccurrences(of: resolvedDirectory.path + "/", with: "")
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
            let fileLength = Int(data.subdata(in: offset ..< offset + 8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            offset += 8

            guard offset + fileLength <= data.count else {
                throw BundleError.unpackingFailed("truncated file data")
            }
            let fileData = data.subdata(in: offset ..< offset + fileLength)
            offset += fileLength

            let fileURL = directory.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fileData.write(to: fileURL)
        }
    }
}
