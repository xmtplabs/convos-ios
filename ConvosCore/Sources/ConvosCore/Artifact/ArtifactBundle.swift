import Foundation

public struct ArtifactBundle: Sendable, Equatable {
    public let manifest: ArtifactManifest
    public let previewHTMLURL: URL
    public let artifactHTMLURL: URL
    public let previewHash: String

    public init(
        manifest: ArtifactManifest,
        previewHTMLURL: URL,
        artifactHTMLURL: URL,
        previewHash: String
    ) {
        self.manifest = manifest
        self.previewHTMLURL = previewHTMLURL
        self.artifactHTMLURL = artifactHTMLURL
        self.previewHash = previewHash
    }
}
