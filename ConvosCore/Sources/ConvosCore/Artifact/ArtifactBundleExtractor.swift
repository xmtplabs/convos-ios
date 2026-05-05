import CryptoKit
import Foundation
import ZIPFoundation

public enum ArtifactBundleExtractorError: Error, Equatable {
    case unzipFailed
    case missingManifest
    case missingPreview
    case missingArtifact
    case malformedManifest
}

public enum ArtifactBundleExtractor {
    public static let manifestFilename: String = "manifest.json"
    public static let previewFilename: String = "preview.html"
    public static let artifactFilename: String = "artifact.html"

    public static func extract(zipURL: URL, into destination: URL) throws -> ArtifactBundle {
        let fileManager: FileManager = .default

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try fileManager.unzipItem(at: zipURL, to: destination)
        } catch {
            throw ArtifactBundleExtractorError.unzipFailed
        }

        return try bundle(at: destination)
    }

    public static func bundle(at directory: URL) throws -> ArtifactBundle {
        let fileManager: FileManager = .default
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        let previewURL = directory.appendingPathComponent(previewFilename)
        let artifactURL = directory.appendingPathComponent(artifactFilename)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ArtifactBundleExtractorError.missingManifest
        }
        guard fileManager.fileExists(atPath: previewURL.path) else {
            throw ArtifactBundleExtractorError.missingPreview
        }
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            throw ArtifactBundleExtractorError.missingArtifact
        }

        let manifest = try parseManifest(at: manifestURL)
        let previewHash = try sha256Hex(of: previewURL)

        return ArtifactBundle(
            manifest: manifest,
            previewHTMLURL: previewURL,
            artifactHTMLURL: artifactURL,
            previewHash: previewHash
        )
    }

    private static func parseManifest(at url: URL) throws -> ArtifactManifest {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ArtifactManifest.self, from: data)
        } catch {
            throw ArtifactBundleExtractorError.malformedManifest
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
