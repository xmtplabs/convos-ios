@testable import ConvosCore
import Foundation
import Testing

/// `BackupBundle` — tar pack/unpack + crypto + metadata round-trip.
///
/// Covers the three-part contract the bundle layer owns:
/// 1. Pack/unpack is a clean round-trip for arbitrary staging layouts.
/// 2. Header (magic + version) rejects non-bundle / future-format blobs.
/// 3. Path-traversal (including symlink escape) cannot escape the
///    staging directory during unpack.
@Suite("BackupBundle")
struct BackupBundleTests {
    // MARK: - Round-trip

    @Test("pack then unpack restores all entries byte-for-byte")
    func testRoundTrip() throws {
        let source = try makeTempDir()
        defer { BackupBundle.cleanup(directory: source) }

        let contents: [(String, Data)] = [
            ("convos-single-inbox.sqlite", Data(repeating: 0x01, count: 4_096)),
            ("xmtp-archive.bin", Data(repeating: 0x02, count: 8_192)),
            ("metadata.json", Data("{\"version\":1}".utf8)),
        ]
        for (name, data) in contents {
            try data.write(to: source.appendingPathComponent(name))
        }

        let key = try BackupBundleCrypto.generateArchiveKey()
        let sealed = try BackupBundle.pack(directory: source, encryptionKey: key)

        let destination = try makeTempDir()
        defer { BackupBundle.cleanup(directory: destination) }
        try BackupBundle.unpack(data: sealed, encryptionKey: key, to: destination)

        for (name, original) in contents {
            let restored = try Data(contentsOf: destination.appendingPathComponent(name))
            #expect(restored == original, "\(name) did not round-trip")
        }
    }

    @Test("unpack rejects blobs without the CVBD magic header")
    func testRejectsMissingMagic() throws {
        let stagingForPack = try makeTempDir()
        defer { BackupBundle.cleanup(directory: stagingForPack) }
        try Data("payload".utf8).write(to: stagingForPack.appendingPathComponent("file.txt"))

        let key = try BackupBundleCrypto.generateArchiveKey()
        let sealed = try BackupBundle.pack(directory: stagingForPack, encryptionKey: key)

        // Strip the outer seal so we can inspect the decrypted tar,
        // then corrupt the magic and re-seal.
        var tar = try BackupBundleCrypto.decrypt(data: sealed, key: key)
        tar[0] = 0x00
        tar[1] = 0x00
        tar[2] = 0x00
        tar[3] = 0x00
        let corrupted = try BackupBundleCrypto.encrypt(data: tar, key: key)

        let destination = try makeTempDir()
        defer { BackupBundle.cleanup(directory: destination) }
        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.unpack(data: corrupted, encryptionKey: key, to: destination)
        }
    }

    @Test("unpack rejects unsupported format versions")
    func testRejectsFutureVersion() throws {
        let stagingForPack = try makeTempDir()
        defer { BackupBundle.cleanup(directory: stagingForPack) }
        try Data("payload".utf8).write(to: stagingForPack.appendingPathComponent("file.txt"))

        let key = try BackupBundleCrypto.generateArchiveKey()
        let sealed = try BackupBundle.pack(directory: stagingForPack, encryptionKey: key)

        var tar = try BackupBundleCrypto.decrypt(data: sealed, key: key)
        // Position 4 is the 1-byte version field, right after the 4-byte magic.
        tar[4] = 0xFF
        let corrupted = try BackupBundleCrypto.encrypt(data: tar, key: key)

        let destination = try makeTempDir()
        defer { BackupBundle.cleanup(directory: destination) }
        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.unpack(data: corrupted, encryptionKey: key, to: destination)
        }
    }

    // MARK: - Path traversal

    @Test("unpack refuses entries whose relative path escapes the staging dir")
    func testRejectsPathTraversal() throws {
        let key = try BackupBundleCrypto.generateArchiveKey()
        // Hand-craft a tar with the correct header but a "../escape" entry.
        var tar = Data()
        tar.append(contentsOf: BackupBundle.magic)
        tar.append(BackupBundle.currentFormatVersion)

        let relativePath = "../escape.bin"
        let fileData = Data("escape-me".utf8)
        var pathLength = UInt32(relativePath.utf8.count).bigEndian
        var fileLength = UInt64(fileData.count).bigEndian
        tar.append(Data(bytes: &pathLength, count: 4))
        tar.append(Data(relativePath.utf8))
        tar.append(Data(bytes: &fileLength, count: 8))
        tar.append(fileData)

        let sealed = try BackupBundleCrypto.encrypt(data: tar, key: key)
        let destination = try makeTempDir()
        defer { BackupBundle.cleanup(directory: destination) }

        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.unpack(data: sealed, encryptionKey: key, to: destination)
        }

        // And the traversal target must not exist on disk afterwards.
        let escapeTarget = destination.deletingLastPathComponent().appendingPathComponent("escape.bin")
        #expect(!FileManager.default.fileExists(atPath: escapeTarget.path))
    }

    // MARK: - Crypto

    @Test("crypto rejects keys of the wrong length")
    func testCryptoRejectsWrongKeyLength() {
        let payload = Data("hi".utf8)
        let badKey = Data(repeating: 0x00, count: 16)
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.encrypt(data: payload, key: badKey)
        }
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: payload, key: badKey)
        }
    }

    @Test("generated archive keys are 32 bytes and random")
    func testGeneratedArchiveKey() throws {
        let a = try BackupBundleCrypto.generateArchiveKey()
        let b = try BackupBundleCrypto.generateArchiveKey()
        #expect(a.count == 32)
        #expect(b.count == 32)
        #expect(a != b, "two consecutive generateArchiveKey() calls must not collide")
    }

    // MARK: - Metadata

    @Test("full metadata round-trips through writeFull / readFull")
    func testFullMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { BackupBundle.cleanup(directory: dir) }
        let key = try BackupBundleCrypto.generateArchiveKey()
        let original = BackupBundleMetadata(
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceId: "device-id",
            deviceName: "Test iPhone",
            osString: "ios",
            conversationCount: 7,
            schemaGeneration: "single-inbox-v2",
            appVersion: "3.14.0",
            archiveKey: key
        )
        try BackupBundleMetadata.writeFull(original, to: dir)
        let loaded = try BackupBundleMetadata.readFull(from: dir)
        #expect(loaded == original)
        #expect(loaded.archiveKey == key)
    }

    @Test("sidecar omits archiveKey and readSidecar succeeds on both files")
    func testSidecarOmitsArchiveKey() throws {
        let sidecarDir = try makeTempDir()
        let tarDir = try makeTempDir()
        defer {
            BackupBundle.cleanup(directory: sidecarDir)
            BackupBundle.cleanup(directory: tarDir)
        }
        let key = try BackupBundleCrypto.generateArchiveKey()
        // ISO8601 encoding loses sub-second precision; pin a whole-second
        // date so the round-trip equality check is deterministic.
        let full = BackupBundleMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceId: "device-id",
            deviceName: "Test iPhone",
            osString: "ios",
            conversationCount: 3,
            schemaGeneration: "single-inbox-v2",
            appVersion: "3.14.0",
            archiveKey: key
        )
        try BackupBundleMetadata.writeFull(full, to: tarDir)
        try BackupBundleMetadata.writeSidecar(full.sidecar, to: sidecarDir)

        let sidecarBytes = try Data(contentsOf: sidecarDir.appendingPathComponent("metadata.json"))
        let sidecarJSON = try #require(String(data: sidecarBytes, encoding: .utf8))
        #expect(!sidecarJSON.contains("archiveKey"), "sidecar must not contain archiveKey")

        // Sidecar reads cleanly.
        let sidecarFromSidecarFile = try BackupBundleMetadata.readSidecar(from: sidecarDir)
        #expect(sidecarFromSidecarFile == full.sidecar)

        // Sidecar reads cleanly from the full file too (extra key is ignored).
        let sidecarFromFullFile = try BackupBundleMetadata.readSidecar(from: tarDir)
        #expect(sidecarFromFullFile == full.sidecar)
    }

    @Test("readFull fails when archiveKey is missing")
    func testReadFullFailsWithoutArchiveKey() throws {
        let dir = try makeTempDir()
        defer { BackupBundle.cleanup(directory: dir) }
        let sidecar = BackupBundleMetadata.Sidecar(
            version: 1,
            createdAt: Date(),
            deviceId: "id",
            deviceName: "name",
            osString: "ios",
            conversationCount: 0,
            schemaGeneration: "single-inbox-v2",
            appVersion: "3.14.0"
        )
        try BackupBundleMetadata.writeSidecar(sidecar, to: dir)

        #expect(throws: DecodingError.self) {
            _ = try BackupBundleMetadata.readFull(from: dir)
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-bundle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
