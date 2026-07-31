import ConvosCore
import CryptoKit
import Foundation
import Observation

/// Gate for the artifact live-preview harness.
///
/// Reachable two ways: manually from the debug menu, or auto-presented at
/// launch when `dev/artifact-preview` starts the app with
/// `CONVOS_ARTIFACT_PREVIEW=1`. Both paths are non-production only.
enum ArtifactPreviewGate {
    static func isAvailable(for environment: AppEnvironment) -> Bool {
        !environment.isProduction
    }

    /// True when the launch environment asked for the harness to open by
    /// itself. Pass to a simulator app as `SIMCTL_CHILD_CONVOS_ARTIFACT_PREVIEW`.
    static var isAutoPresentRequested: Bool {
        guard isAvailable(for: ConfigManager.shared.currentEnvironment) else { return false }
        return ProcessInfo.processInfo.environment["CONVOS_ARTIFACT_PREVIEW"] == "1"
    }
}

/// Watches a drop directory inside the app container and republishes
/// whichever HTML file was written most recently, so an artifact edited on
/// the Mac re-renders in the app on save.
///
/// The published `attachmentKey` carries a hash of the file's bytes. Both
/// `HTMLThumbnailRenderer` and `HTMLContentPrewarmer` key their caches on
/// that string, so a changed file lands on a fresh key and neither cache
/// can serve the previous render.
@MainActor
@Observable
final class ArtifactPreviewStore {
    struct Artifact: Equatable {
        let fileURL: URL
        let filename: String
        let contentHash: String
        let byteCount: Int
        let loadedAt: Date

        /// Namespaced so a preview render can never collide with a real
        /// attachment's cache entry.
        var attachmentKey: String {
            Constant.attachmentKeyPrefix + contentHash
        }
    }

    private(set) var artifact: Artifact?
    private(set) var reloadCount: Int = 0
    private(set) var lastError: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: Task<Void, Never>?

    /// `Documents/` rather than `Caches/` deliberately: the caches directory
    /// is evictable under disk pressure, and a preview that vanishes
    /// mid-session reads as a bug in the harness.
    static var dropDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(Constant.directoryName, isDirectory: true)
    }

    func start() {
        createDropDirectoryIfNeeded()
        reload()
        startWatching()
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Rescans the drop directory. Republishes only when the bytes actually
    /// changed, so an editor's touch-without-save (or the directory event
    /// raised by our own read) does not churn the render.
    func reload() {
        guard let candidate = newestHTMLFile() else {
            artifact = nil
            lastError = nil
            return
        }
        do {
            let data = try Data(contentsOf: candidate)
            let hash = Self.shortHash(of: data)
            guard hash != artifact?.contentHash else { return }
            artifact = Artifact(
                fileURL: candidate,
                filename: candidate.lastPathComponent,
                contentHash: hash,
                byteCount: data.count,
                loadedAt: Date()
            )
            reloadCount += 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.error("ArtifactPreviewStore: failed reading \(candidate.lastPathComponent): \(error)")
        }
    }

    private func createDropDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: Self.dropDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            lastError = error.localizedDescription
            Log.error("ArtifactPreviewStore: failed creating drop directory: \(error)")
        }
    }

    private func newestHTMLFile() -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.dropDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        guard let contents else { return nil }
        let htmlFiles: [URL] = contents.filter { $0.pathExtension.lowercased() == "html" }
        return htmlFiles.max { lhs, rhs in
            Self.modificationDate(of: lhs) < Self.modificationDate(of: rhs)
        }
    }

    private static func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// Watches the directory rather than the file. The delivery script
    /// replaces the artifact atomically (write to a temp name, then rename),
    /// which unlinks the inode a file-level watch is holding - that watch
    /// would fire once and then go permanently deaf.
    private func startWatching() {
        guard watcher == nil else { return }
        let descriptor = open(Self.dropDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            lastError = "Could not watch \(Constant.directoryName) (errno \(errno))"
            Log.error("ArtifactPreviewStore: open() failed with errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleReload()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        watcher = source
    }

    /// Coalesces the burst of directory events a single save produces
    /// (create temp, rename, unlink) into one reload, and lets the writer
    /// finish before we read.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Constant.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private static func shortHash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private enum Constant {
        static let directoryName: String = "ArtifactPreview"
        static let attachmentKeyPrefix: String = "artifact-preview-"
        static let debounceMilliseconds: Int = 150
    }
}
