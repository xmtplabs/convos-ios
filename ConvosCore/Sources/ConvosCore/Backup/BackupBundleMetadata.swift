import Foundation

public struct BackupBundleMetadata: Codable, Sendable, Equatable {
    public let version: Int
    public let createdAt: Date
    public let deviceId: String
    public let deviceName: String
    public let osString: String
    public let inboxCount: Int

    public init(
        version: Int = 1,
        createdAt: Date = Date(),
        deviceId: String,
        deviceName: String,
        osString: String,
        inboxCount: Int
    ) {
        self.version = version
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.osString = osString
        self.inboxCount = inboxCount
    }

    private enum Constant {
        static let metadataFilename: String = "metadata.json"
    }

    static func write(_ metadata: BackupBundleMetadata, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: directory.appendingPathComponent(Constant.metadataFilename))
    }

    public static func read(from directory: URL) throws -> BackupBundleMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent(Constant.metadataFilename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupBundleMetadata.self, from: data)
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(Constant.metadataFilename).path)
    }
}
