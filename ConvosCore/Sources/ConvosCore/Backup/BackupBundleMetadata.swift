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
///
/// Under the two-key model (see `single-inbox-two-key-model.md`), the inner
/// metadata also carries the JSON-encoded `KeychainIdentity` that the
/// destination device adopts on restore. The outer AES-GCM seal protects it.
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
    /// Two-key model: the source device's `KeychainIdentity` JSON. The
    /// destination device adopts this on restore and writes it to its
    /// per-device identity slot. Optional so legacy v1 bundles (pre two-
    /// key refactor) still decode — those produce a `nil` value here and
    /// `RestoreManager` reports `decryptionFailed("legacy bundle has no
    /// identity payload")` when it can't unseal the new way.
    let identityPayload: Data?

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
        archiveMetadata: ArchiveMetadata? = nil,
        identityPayload: Data? = nil
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
        self.identityPayload = identityPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        osString = try container.decode(String.self, forKey: .osString)
        conversationCount = try container.decode(Int.self, forKey: .conversationCount)
        schemaGeneration = try container.decode(String.self, forKey: .schemaGeneration)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        archiveKey = try container.decode(Data.self, forKey: .archiveKey)
        archiveMetadata = try container.decodeIfPresent(ArchiveMetadata.self, forKey: .archiveMetadata)
        // Optional decode so pre-two-key bundles still parse. They'll
        // simply have a nil payload and fail at the adoption step.
        identityPayload = try container.decodeIfPresent(Data.self, forKey: .identityPayload)
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
