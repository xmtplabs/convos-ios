@testable import ConvosCore
import CryptoKit
import Foundation
import Testing

@Suite("BackupBundle Tests")
struct BackupBundleTests {
    private func randomKey() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func freshStaging() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundletests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("pack and unpack round-trips all files in the staging directory")
    func testPackUnpackRoundTrip() throws {
        let staging = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: staging) }

        let dbPath = BackupBundle.databasePath(in: staging)
        let archivePath = BackupBundle.archivePath(in: staging)
        let metaPath = staging.appendingPathComponent(BackupSidecarMetadata.filename)
        try Data("sqlite-bytes".utf8).write(to: dbPath)
        try Data("archive-bytes".utf8).write(to: archivePath)
        try Data("{\"version\":1}".utf8).write(to: metaPath)

        let key = randomKey()
        let packed = try BackupBundle.pack(directory: staging, encryptionKey: key)
        #expect(packed.count > 0)

        let restoreDir = try freshStaging()
        defer { try? FileManager.default.removeItem(at: restoreDir) }
        try BackupBundle.unpack(data: packed, encryptionKey: key, to: restoreDir)

        #expect(try Data(contentsOf: BackupBundle.databasePath(in: restoreDir)) == Data("sqlite-bytes".utf8))
        #expect(try Data(contentsOf: BackupBundle.archivePath(in: restoreDir)) == Data("archive-bytes".utf8))
        #expect(try Data(contentsOf: restoreDir.appendingPathComponent(BackupSidecarMetadata.filename)) == Data("{\"version\":1}".utf8))
    }

    @Test("unpack rejects a bundle without the CVBD magic prefix")
    func testRejectsInvalidMagic() throws {
        let key = randomKey()
        // Seal a non-CVBD payload directly so the outer AES-GCM opens, but the
        // unpacked framed bytes fail the magic check.
        let sealedWithoutHeader = try BackupBundleCrypto.encrypt(
            data: Data("xxxxxxxxxxxxxx".utf8),
            key: key
        )
        let restoreDir = try freshStaging()
        defer { try? FileManager.default.removeItem(at: restoreDir) }

        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.unpack(data: sealedWithoutHeader, encryptionKey: key, to: restoreDir)
        }
    }

    @Test("unpack rejects an unsupported format version")
    func testRejectsUnsupportedFormatVersion() throws {
        let key = randomKey()
        var framed = Data()
        framed.append(Data("CVBD".utf8))
        framed.append(UInt8(99))
        framed.append(Data("garbage".utf8))
        let sealed = try BackupBundleCrypto.encrypt(data: framed, key: key)
        let restoreDir = try freshStaging()
        defer { try? FileManager.default.removeItem(at: restoreDir) }

        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.unpack(data: sealed, encryptionKey: key, to: restoreDir)
        }
    }

    @Test("pack does not exfiltrate file content via a symlink pointing outside staging")
    func testSymlinkCannotExfiltrateOutsideContent() throws {
        let staging = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: staging) }
        let outside = try freshStaging()
        defer { try? FileManager.default.removeItem(at: outside) }

        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("SUPERSECRET".utf8).write(to: outsideFile)

        let symlinkPath = staging.appendingPathComponent("loot")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideFile)

        // Either the enumerator skips the symlink (safe — never tarred) or the
        // resolved-path containment check throws. Both outcomes prevent
        // exfiltration; assert on the exfiltration property directly.
        do {
            let tar = try BackupBundle.tarDirectory(staging)
            #expect(!tar.contains(Data("SUPERSECRET".utf8)))
        } catch {
            #expect(error is BackupBundle.BundleError)
        }
    }

    @Test("untar rejects a relative path that escapes the target directory")
    func testRejectsPathTraversalOnUntar() throws {
        // Build a tar entry by hand with relative path "../escape.txt".
        let target = try freshStaging()
        defer { try? FileManager.default.removeItem(at: target) }
        var tar = Data()
        let path = "../escape.txt"
        let pathBytes = Data(path.utf8)
        var pathLen = UInt32(pathBytes.count).bigEndian
        tar.append(Data(bytes: &pathLen, count: 4))
        tar.append(pathBytes)
        let fileBytes = Data("payload".utf8)
        var fileLen = UInt64(fileBytes.count).bigEndian
        tar.append(Data(bytes: &fileLen, count: 8))
        tar.append(fileBytes)

        #expect(throws: BackupBundle.BundleError.self) {
            try BackupBundle.untarData(tar, to: target)
        }
    }

    @Test("unpack detects a truncated payload")
    func testTruncatedPayloadFails() throws {
        let staging = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: staging) }
        try Data("x".utf8).write(to: BackupBundle.databasePath(in: staging))

        let key = randomKey()
        var packed = try BackupBundle.pack(directory: staging, encryptionKey: key)
        // Snip off the last 8 bytes — the AES-GCM tag sits at the end, so auth fails.
        packed = packed.dropLast(8)
        let restoreDir = try freshStaging()
        defer { try? FileManager.default.removeItem(at: restoreDir) }

        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            try BackupBundle.unpack(data: packed, encryptionKey: key, to: restoreDir)
        }
    }
}
