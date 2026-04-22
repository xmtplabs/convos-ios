import Foundation

/// Metadata that accompanies a backup bundle.
///
/// Two serialized forms, written to two different locations:
/// - **Internal** (`writeFull(to:)`): written inside the encrypted tar,
///   includes `archiveKey` so `RestoreManager` can decrypt the inner
///   `xmtp-archive.bin`. Read after the outer seal is opened.
/// - **Sidecar** (`writeSidecar(to:)`): written next to
///   `backup-latest.encrypted`, unencrypted, omits every secret.
///   Powers `RestoreManager.findAvailableBackup` discovery without
///   requiring the bundle key.
///
/// The only secret carried here is `archiveKey`. Everything else is
/// safe to expose in the sidecar.
public struct BackupBundleMetadata: Codable, Sendable, Equatable {
    public let version: Int
    public let createdAt: Date
    public let deviceId: String
    public let deviceName: String
    public let osString: String
    public let conversationCount: Int
    public let schemaGeneration: String
    public let appVersion: String
    /// 32-byte XMTP archive key. Fresh CSPRNG per bundle. Required to
    /// decrypt `xmtp-archive.bin`. Never written to the sidecar.
    public let archiveKey: Data

    public init(
        version: Int = Self.currentVersion,
        createdAt: Date = Date(),
        deviceId: String,
        deviceName: String,
        osString: String,
        conversationCount: Int,
        schemaGeneration: String,
        appVersion: String,
        archiveKey: Data
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
    }

    public static let currentVersion: Int = 1

    /// Secret-free projection. This is what the sidecar file contains.
    public var sidecar: Sidecar {
        Sidecar(
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

    public struct Sidecar: Codable, Sendable, Equatable {
        public let version: Int
        public let createdAt: Date
        public let deviceId: String
        public let deviceName: String
        public let osString: String
        public let conversationCount: Int
        public let schemaGeneration: String
        public let appVersion: String

        public init(
            version: Int,
            createdAt: Date,
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
    }

    // MARK: - I/O

    /// Write the full metadata (including `archiveKey`) into a tar
    /// staging directory as `metadata.json`.
    public static func writeFull(_ metadata: BackupBundleMetadata, to directory: URL) throws {
        let data = try jsonEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent(Constant.filename))
    }

    /// Write the secret-free sidecar to a backup directory (next to
    /// `backup-latest.encrypted`) as `metadata.json`.
    public static func writeSidecar(_ sidecar: Sidecar, to directory: URL) throws {
        let data = try jsonEncoder().encode(sidecar)
        try data.write(to: directory.appendingPathComponent(Constant.filename))
    }

    /// Read the full metadata from an unpacked tar staging directory.
    /// Fails if `archiveKey` is missing.
    public static func readFull(from directory: URL) throws -> BackupBundleMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent(Constant.filename))
        return try jsonDecoder().decode(BackupBundleMetadata.self, from: data)
    }

    /// Read the sidecar-shaped metadata. Works on either the sidecar
    /// file next to the bundle or the inside-tar file.
    ///
    /// Load-bearing detail: the `Sidecar` decoder relies on
    /// `JSONDecoder`'s default "ignore unknown keys" behavior to
    /// accept full-form input (where `archiveKey` is also present).
    /// Do not switch this decoder to a strict mode without adding an
    /// explicit "project to sidecar" step — callers that hand a
    /// full-form file to this function expect success, not a decode
    /// error on the extra key.
    public static func readSidecar(from directory: URL) throws -> Sidecar {
        let data = try Data(contentsOf: directory.appendingPathComponent(Constant.filename))
        return try jsonDecoder().decode(Sidecar.self, from: data)
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Constant.filename).path
        )
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum Constant {
        static let filename: String = "metadata.json"
    }
}
