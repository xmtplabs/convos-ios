import Foundation

/// Durable staging for agent builds, the photo-outbox principle applied to
/// Make. The share extension writes the prompt and compressed photo bytes to
/// the app-group container before any network work; the record is cleared as
/// soon as the generation is submitted (the persisted generation row takes
/// over the delivery guarantee from there). If the extension process dies
/// mid-creation - jetsam kills during conversation setup are the observed
/// failure - the main app's foreground drain finds the record and finishes
/// the build through the same `AgentCreationFlow`.
public enum AgentBuildOutbox {
    public struct StagedBuild {
        public let id: String
        public let prompt: String
        public let photoJPEGs: [Data]
        public let createdAt: Date
    }

    private struct Manifest: Codable {
        let id: String
        let prompt: String
        let photoFiles: [String]
        let createdAt: Date
    }

    /// Persists a build before the creation attempt starts. Photos are
    /// written first and the manifest last, so a record without a manifest
    /// (kill mid-stage) is invisible to the drain and gets swept as expired.
    public static func stage(prompt: String, photoJPEGs: [Data]) throws -> String {
        let id = UUID().uuidString
        let dir = try buildsDirectory().appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var photoFiles: [String] = []
        for (index, data) in photoJPEGs.enumerated() {
            let name = "photo_\(index).jpg"
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            photoFiles.append(name)
        }
        let manifest = Manifest(id: id, prompt: prompt, photoFiles: photoFiles, createdAt: Date())
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: dir.appendingPathComponent(Constant.manifestName), options: .atomic)
        Log.info("AgentBuildOutbox: staged build \(id) photos=\(photoFiles.count)")
        return id
    }

    /// Removes a staged record once the generation row exists (or the drain
    /// finished it). Safe to call for an already-cleared id.
    public static func clear(id: String) {
        guard let dir = try? buildsDirectory().appendingPathComponent(id, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Staged builds old enough that the process which staged them is
    /// certainly gone (the extension's in-sheet attempt plus its expiring-
    /// activity runway fit well inside the grace window), and young enough
    /// that finishing them won't surprise the user.
    public static func pendingBuilds(now: Date = Date()) -> [StagedBuild] {
        guard let root = try? buildsDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var builds: [StagedBuild] = []
        for dir in entries {
            let manifestURL = dir.appendingPathComponent(Constant.manifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                // No readable manifest: either a mid-stage kill or corruption.
                // Sweep it once it is old enough that no live stage can be
                // writing here.
                if let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                   now.timeIntervalSince(created) > Constant.graceWindow {
                    try? FileManager.default.removeItem(at: dir)
                }
                continue
            }
            let age = now.timeIntervalSince(manifest.createdAt)
            if age > Constant.maxAge {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            guard age > Constant.graceWindow else { continue }
            let photos: [Data] = manifest.photoFiles.compactMap { name in
                try? Data(contentsOf: dir.appendingPathComponent(name))
            }
            builds.append(StagedBuild(id: manifest.id, prompt: manifest.prompt, photoJPEGs: photos, createdAt: manifest.createdAt))
        }
        return builds.sorted { $0.createdAt < $1.createdAt }
    }

    /// Finishes builds a dead extension process left behind. Called from the
    /// main app on foreground, alongside `OutgoingMessageDrain`.
    public static func drain(
        session: any SessionManagerProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) async {
        let builds = pendingBuilds()
        guard !builds.isEmpty else { return }
        Log.info("AgentBuildOutbox: draining \(builds.count) staged build(s)")
        for build in builds {
            do {
                let prepared = AgentCreationFlow.prepareAttachments(storedPhotoJPEGs: build.photoJPEGs)
                let created = try await AgentCreationFlow.createAgent(
                    prompt: build.prompt,
                    prepared: prepared,
                    session: session
                )
                clear(id: build.id)
                try await AgentCreationFlow.sendPrompt(
                    for: created,
                    session: session,
                    backgroundUploadManager: backgroundUploadManager
                )
                Log.info("AgentBuildOutbox: drained build \(build.id) into \(created.conversationId)")
            } catch {
                // Leave the record for the next foreground; maxAge caps how
                // long a persistently failing build is retried.
                Log.error("AgentBuildOutbox: drain failed for \(build.id): \(error.localizedDescription)")
            }
        }
    }

    private static func buildsDirectory() throws -> URL {
        let base: URL
        if let appGroup = PhotoAttachmentService.sharedContainerAppGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            base = container.appendingPathComponent("Library/Caches", isDirectory: true)
        } else if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = cacheDir
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        return base.appendingPathComponent(Constant.directoryName, isDirectory: true)
    }

    private enum Constant {
        static let directoryName: String = "PendingAgentBuilds"
        static let manifestName: String = "manifest.json"
        /// The staging process gets this long to finish on its own before the
        /// drain may take over: the in-sheet attempt (a few seconds) plus the
        /// ~25s expiring-activity runway fit comfortably inside it.
        static let graceWindow: TimeInterval = 90
        /// Builds older than this are dropped rather than finished - silently
        /// creating a long-forgotten agent would surprise more than help.
        static let maxAge: TimeInterval = 48 * 60 * 60
    }
}
