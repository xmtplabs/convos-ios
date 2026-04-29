@testable import ConvosCore
import Foundation
import Testing

@Suite("BackupBundleMetadata Tests")
struct BackupBundleMetadataTests {
    private func freshDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metatests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("sidecar round-trips through JSON")
    func testSidecarRoundTrip() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = BackupSidecarMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceId: "device-123",
            deviceName: "Test iPhone",
            osString: "ios",
            conversationCount: 7,
            schemaGeneration: "v1-single-inbox",
            appVersion: "2.3.4"
        )
        try BackupSidecarMetadata.write(sidecar, to: dir)
        #expect(BackupSidecarMetadata.exists(in: dir))
        let decoded = try BackupSidecarMetadata.read(from: dir)
        #expect(decoded == sidecar)
    }

    @Test("inner metadata carries archiveKey and projects a sidecar without it")
    func testInnerToSidecarProjection() throws {
        let archiveKey = Data(repeating: 0xAB, count: 32)
        let inner = BackupBundleMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceId: "device-456",
            deviceName: "Test iPad",
            osString: "ios",
            conversationCount: 3,
            schemaGeneration: "v1-single-inbox",
            appVersion: "2.3.4",
            archiveKey: archiveKey,
            archiveMetadata: .init(startNs: 1, endNs: 2)
        )

        let sidecar = inner.sidecar
        #expect(sidecar.deviceId == inner.deviceId)
        #expect(sidecar.deviceName == inner.deviceName)
        #expect(sidecar.conversationCount == inner.conversationCount)
        #expect(sidecar.schemaGeneration == inner.schemaGeneration)
        #expect(sidecar.appVersion == inner.appVersion)
    }

    @Test("sidecar JSON does not leak archiveKey or archiveMetadata fields")
    func testSidecarJsonExcludesSecrets() throws {
        let sidecar = BackupSidecarMetadata(
            deviceId: "d",
            deviceName: "n",
            osString: "ios",
            conversationCount: 1,
            schemaGeneration: "v1-single-inbox",
            appVersion: "1.0.0"
        )
        let data = try BackupMetadataCoders.encoder.encode(sidecar)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("archiveKey"))
        #expect(!json.contains("archiveMetadata"))
    }

    @Test("inner metadata encodes archiveKey into its JSON")
    func testInnerJsonIncludesArchiveKey() throws {
        let archiveKey = Data(repeating: 0x11, count: 32)
        let inner = BackupBundleMetadata(
            deviceId: "d",
            deviceName: "n",
            osString: "ios",
            conversationCount: 0,
            schemaGeneration: "v1-single-inbox",
            appVersion: "1.0.0",
            archiveKey: archiveKey
        )
        let data = try BackupMetadataCoders.encoder.encode(inner)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("archiveKey"))
    }
}
