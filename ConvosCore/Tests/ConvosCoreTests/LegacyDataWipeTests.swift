@testable import ConvosCore
import Foundation
import Testing

/// Unit coverage for the generation-gated wipe at app launch. Each test
/// runs against a fresh temp directory and a private `UserDefaults` suite,
/// so state doesn't leak between tests or into the real app-group.
@Suite("LegacyDataWipe", .serialized)
struct LegacyDataWipeTests {
    // Keychain access group is only used for legacy v1/v2 delete attempts,
    // which return errSecItemNotFound in the test simulator keychain and
    // never contribute to the gate — safe to pass a dummy value.
    private let legacyAccessGroup = "group.org.convos.tests.legacy-wipe"

    @Test("Fresh install: no artifacts, marker set on first run")
    func freshInstallMarkerSet() throws {
        let fixture = try TempFixture()

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == LegacyDataWipe.currentGeneration)
    }

    @Test("Marker already current: no-op")
    func markerAlreadyCurrentIsNoOp() throws {
        let fixture = try TempFixture()
        fixture.defaults.set(LegacyDataWipe.currentGeneration, forKey: "convos.schemaGeneration")

        // Drop a "legacy" file to prove the wipe didn't run — if it had,
        // this file would be deleted.
        let grdb = fixture.databasesDirectory.appendingPathComponent("convos.sqlite")
        try Data("would-have-been-wiped".utf8).write(to: grdb)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(FileManager.default.fileExists(atPath: grdb.path))
    }

    @Test("Compatible legacy generation 'single-inbox-v2' is treated as current — no wipe, marker forwarded")
    func compatibleGenerationIsNotWiped() throws {
        let fixture = try TempFixture()
        // Existing dev install: marker is the prior canonical name, the
        // active xmtp-*.db3 files are present. The wipe must NOT run.
        fixture.defaults.set("single-inbox-v2", forKey: "convos.schemaGeneration")
        let activeXmtp = fixture.databasesDirectory
            .appendingPathComponent("xmtp-grpc.dev.xmtp.network-abc123.db3")
        try Data("active-xmtp-db".utf8).write(to: activeXmtp)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(FileManager.default.fileExists(atPath: activeXmtp.path))
        #expect(
            fixture.defaults.string(forKey: "convos.schemaGeneration")
            == LegacyDataWipe.currentGeneration
        )
    }

    @Test("Upgrade: legacy artifacts removed + marker set")
    func upgradeWipesAndMarksGeneration() throws {
        let fixture = try TempFixture()

        // Simulate an old install: legacy marker + legacy GRDB + xmtp files
        // under the real SDK filename shape (xmtp-grpc.<host>-<hash>.db3).
        fixture.defaults.set("single-inbox-v1", forKey: "convos.schemaGeneration")
        let grdb = fixture.databasesDirectory.appendingPathComponent("convos.sqlite")
        try Data("old-db".utf8).write(to: grdb)
        let xmtpDb = fixture.databasesDirectory.appendingPathComponent("xmtp-grpc.dev.xmtp.network-abc123.db3")
        try Data("old-xmtp".utf8).write(to: xmtpDb)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(!FileManager.default.fileExists(atPath: grdb.path))
        #expect(!FileManager.default.fileExists(atPath: xmtpDb.path))
        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == LegacyDataWipe.currentGeneration)
    }

    @Test("Upgrade from pre-refactor main: xmtp-grpc.<host>-<hash>.db3 sidecars all removed")
    func upgradeRemovesXmtpGrpcFilenameFamily() throws {
        let fixture = try TempFixture()

        // No prior marker (main branch never set one). Seed the exact
        // filename shape XMTPiOS produces — the original wipe looked for
        // `xmtp-{env}-` which never matched these, so upgrade silently
        // no-opped and db3 sidecars leaked on every install.
        let base = "xmtp-grpc.dev.xmtp.network-2b157ccd2a467e2096e8942a73422358c4dcdd777e1541d46ff80f558be56ad1"
        let files = [
            "\(base).db3",
            "\(base).db3-shm",
            "\(base).db3-wal",
            "\(base).db3.sqlcipher_salt"
        ]
        for filename in files {
            let url = fixture.databasesDirectory.appendingPathComponent(filename)
            try Data("legacy".utf8).write(to: url)
        }

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        for filename in files {
            let url = fixture.databasesDirectory.appendingPathComponent(filename)
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(filename) should be gone")
        }
        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == LegacyDataWipe.currentGeneration)
    }

    @Test("Cold install but with legacy artifacts (no marker): still wipes + marks")
    func noMarkerButArtifactsTriggersWipe() throws {
        let fixture = try TempFixture()

        // No generation marker, but legacy artifacts on disk — e.g. the
        // marker got cleared but the files persisted. Must still wipe.
        let grdb = fixture.databasesDirectory.appendingPathComponent("convos.sqlite")
        try Data("old-db".utf8).write(to: grdb)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(!FileManager.default.fileExists(atPath: grdb.path))
        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == LegacyDataWipe.currentGeneration)
    }

    @Test("Idempotent: running twice on same generation is a no-op on the second run")
    func idempotentAcrossRuns() throws {
        let fixture = try TempFixture()

        // First run: fresh install, marker gets set.
        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )
        let firstMarker = fixture.defaults.string(forKey: "convos.schemaGeneration")

        // Drop a file after the first run — it should survive the second run
        // because the second run short-circuits on the current-generation marker.
        let newFile = fixture.databasesDirectory.appendingPathComponent("convos.sqlite")
        try Data("written-after-first-run".utf8).write(to: newFile)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == firstMarker)
        #expect(FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test("Generation bump forces re-wipe on next launch")
    func generationBumpReWipes() throws {
        let fixture = try TempFixture()

        // Pretend we're on an older generation.
        fixture.defaults.set("single-inbox-v0", forKey: "convos.schemaGeneration")
        let grdb = fixture.databasesDirectory.appendingPathComponent("convos.sqlite")
        try Data("stale".utf8).write(to: grdb)

        LegacyDataWipe.runIfNeeded(
            defaults: fixture.defaults,
            databasesDirectory: fixture.databasesDirectory,
            legacyKeychainAccessGroup: legacyAccessGroup
        )

        #expect(!FileManager.default.fileExists(atPath: grdb.path))
        #expect(fixture.defaults.string(forKey: "convos.schemaGeneration") == LegacyDataWipe.currentGeneration)
    }
}

// MARK: - Fixture

private final class TempFixture {
    let databasesDirectory: URL
    let defaults: UserDefaults
    private let defaultsSuite: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyDataWipeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        databasesDirectory = base

        defaultsSuite = "convos.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.defaultsAllocationFailed
        }
        self.defaults = defaults
    }

    deinit {
        try? FileManager.default.removeItem(at: databasesDirectory)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}

private enum FixtureError: Error {
    case defaultsAllocationFailed
}
