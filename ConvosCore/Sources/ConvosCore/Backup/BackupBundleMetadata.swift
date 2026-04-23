import Foundation

/// Discovery sidecar written alongside `backup-latest.encrypted` in the backup
/// directory. Unencrypted so `RestoreManager.findAvailableBackup` can read it
/// without touching the bundle key. Carries no secrets — the `archiveKey` that
/// seals `xmtp-archive.bin` lives only in the inner metadata inside the tar.
public struct BackupSidecarMetadata: Codable, Sendable, Equatable {
    public static let currentVersion: Int = 1
    public static let filename: String = "metadata.json"

    public let version: Int
    public let createdAt: Date
    public let deviceId: String
    public let deviceName: String
    public let osString: String
    public let conversationCount: Int
    public let schemaGeneration: String
    public let appVersion: String

    public init(
        version: Int = BackupSidecarMetadata.currentVersion,
        createdAt: Date = Date(),
        deviceId: String,
        deviceName: String,
        osString: String,
        conversationCount: Int,
        schemaGeneration: String,
        appVersion: String
    ) {
        self.version = version
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.osString = osString
        self.conversationCount = conversationCount
        self.schemaGeneration = schemaGeneration
        self.appVersion = appVersion
    }

    public static func write(_ metadata: BackupSidecarMetadata, to directory: URL) throws {
        let data = try BackupMetadataCoders.encoder.encode(metadata)
        try data.write(to: directory.appendingPathComponent(filename))
    }

    public static func read(from directory: URL) throws -> BackupSidecarMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent(filename))
        return try BackupMetadataCoders.decoder.decode(BackupSidecarMetadata.self, from: data)
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(filename).path
        )
    }
}

/// Inner metadata written inside the encrypted bundle tar. Superset of the
/// sidecar plus the per-bundle `archiveKey` that seals `xmtp-archive.bin`. The
/// archive key lives only here so it travels under the outer AES-GCM seal —
/// never in the sidecar, which has to stay unencrypted for discovery.
struct BackupBundleMetadata: Codable, Sendable, Equatable {
    struct ArchiveMetadata: Codable, Sendable, Equatable {
        let startNs: Int64?
        let endNs: Int64?
    }

    let version: Int
    let createdAt: Date
    let deviceId: String
    let deviceName: String
    let osString: String
    let conversationCount: Int
    let schemaGeneration: String
    let appVersion: String
    let archiveKey: Data
    let archiveMetadata: ArchiveMetadata?

    init(
        version: Int = BackupSidecarMetadata.currentVersion,
        createdAt: Date = Date(),
        deviceId: String,
        deviceName: String,
        osString: String,
        conversationCount: Int,
        schemaGeneration: String,
        appVersion: String,
        archiveKey: Data,
        archiveMetadata: ArchiveMetadata? = nil
    ) {
        self.version = version
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.osString = osString
        self.conversationCount = conversationCount
        self.schemaGeneration = schemaGeneration
        self.appVersion = appVersion
        self.archiveKey = archiveKey
        self.archiveMetadata = archiveMetadata
    }

    var sidecar: BackupSidecarMetadata {
        BackupSidecarMetadata(
            version: version,
            createdAt: createdAt,
            deviceId: deviceId,
            deviceName: deviceName,
            osString: osString,
            conversationCount: conversationCount,
            schemaGeneration: schemaGeneration,
            appVersion: appVersion
        )
    }

    static func write(_ metadata: BackupBundleMetadata, to directory: URL) throws {
        let data = try BackupMetadataCoders.encoder.encode(metadata)
        try data.write(to: directory.appendingPathComponent(BackupSidecarMetadata.filename))
    }

    static func read(from directory: URL) throws -> BackupBundleMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent(BackupSidecarMetadata.filename))
        return try BackupMetadataCoders.decoder.decode(BackupBundleMetadata.self, from: data)
    }
}

enum BackupMetadataCoders {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
