@testable import ConvosCore
import Foundation
import Testing
import ZIPFoundation

@Suite("ArtifactBundleExtractor")
struct ArtifactBundleExtractorTests {
    @Test("extracts a valid bundle and parses the manifest")
    func extractValidBundle() throws {
        let zipURL = try makeZip(files: [
            "manifest.json": """
            {
                "bundle_version": "1",
                "created_at": "2026-05-05T00:00:00Z",
                "title": "Paris Itinerary",
                "summary": "A 3-day plan for Paris."
            }
            """,
            "preview.html": "<html><body>preview</body></html>",
            "artifact.html": "<html><body>artifact</body></html>",
        ])
        let destination = makeTempDirectory()

        let bundle = try ArtifactBundleExtractor.extract(zipURL: zipURL, into: destination)

        #expect(bundle.manifest.title == "Paris Itinerary")
        #expect(bundle.manifest.summary == "A 3-day plan for Paris.")
        #expect(bundle.manifest.bundleVersion == "1")
        #expect(bundle.previewHTMLURL.lastPathComponent == "preview.html")
        #expect(bundle.artifactHTMLURL.lastPathComponent == "artifact.html")
        #expect(bundle.previewHash.count == 64)
    }

    @Test("computes a stable preview hash from preview.html bytes")
    func stablePreviewHash() throws {
        let html = "<html><body>same content</body></html>"
        let firstZip = try makeZip(files: [
            "manifest.json": minimalManifest,
            "preview.html": html,
            "artifact.html": "<html><body>a</body></html>",
        ])
        let secondZip = try makeZip(files: [
            "manifest.json": minimalManifest,
            "preview.html": html,
            "artifact.html": "<html><body>b</body></html>",
        ])

        let firstBundle = try ArtifactBundleExtractor.extract(zipURL: firstZip, into: makeTempDirectory())
        let secondBundle = try ArtifactBundleExtractor.extract(zipURL: secondZip, into: makeTempDirectory())

        #expect(firstBundle.previewHash == secondBundle.previewHash)
    }

    @Test("fails with malformedManifest when JSON is invalid")
    func malformedManifest() throws {
        let zipURL = try makeZip(files: [
            "manifest.json": "{ not valid json",
            "preview.html": "<html></html>",
            "artifact.html": "<html></html>",
        ])
        #expect(throws: ArtifactBundleExtractorError.malformedManifest) {
            try ArtifactBundleExtractor.extract(zipURL: zipURL, into: makeTempDirectory())
        }
    }

    @Test("fails with missingPreview when preview.html is absent")
    func missingPreview() throws {
        let zipURL = try makeZip(files: [
            "manifest.json": minimalManifest,
            "artifact.html": "<html></html>",
        ])
        #expect(throws: ArtifactBundleExtractorError.missingPreview) {
            try ArtifactBundleExtractor.extract(zipURL: zipURL, into: makeTempDirectory())
        }
    }

    @Test("fails with missingArtifact when artifact.html is absent")
    func missingArtifact() throws {
        let zipURL = try makeZip(files: [
            "manifest.json": minimalManifest,
            "preview.html": "<html></html>",
        ])
        #expect(throws: ArtifactBundleExtractorError.missingArtifact) {
            try ArtifactBundleExtractor.extract(zipURL: zipURL, into: makeTempDirectory())
        }
    }

    @Test("accepts unknown bundle_version values for forward compatibility")
    func unknownVersion() throws {
        let zipURL = try makeZip(files: [
            "manifest.json": """
            {
                "bundle_version": "99",
                "created_at": "2099-01-01T00:00:00Z",
                "title": "Future",
                "summary": "From the future."
            }
            """,
            "preview.html": "<html></html>",
            "artifact.html": "<html></html>",
        ])
        let bundle = try ArtifactBundleExtractor.extract(zipURL: zipURL, into: makeTempDirectory())
        #expect(bundle.manifest.bundleVersion == "99")
        #expect(bundle.manifest.title == "Future")
    }

    private let minimalManifest: String = """
    {
        "bundle_version": "1",
        "created_at": "2026-05-05T00:00:00Z",
        "title": "T",
        "summary": "S"
    }
    """

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeZip(files: [String: String]) throws -> URL {
        let stagingDir = makeTempDirectory()
        for (name, content) in files {
            try Data(content.utf8).write(to: stagingDir.appendingPathComponent(name))
        }
        let zipURL = makeTempDirectory().appendingPathComponent("bundle.artifact")
        try FileManager.default.zipItem(at: stagingDir, to: zipURL, shouldKeepParent: false)
        return zipURL
    }
}
