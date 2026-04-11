import ConvosCore
import QuickLook
import UIKit

enum FileAttachmentPreviewLoader {
    static func loadPreviewURL(key: String, filename: String?) async throws -> URL {
        let name = filename ?? "attachment"

        if key.hasPrefix("file://") {
            let path = String(key.dropFirst("file://".count))
            let sourceURL = URL(fileURLWithPath: path)

            if FileManager.default.fileExists(atPath: path) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("preview_\(UUID().uuidString)")
                    .appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: tempURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                return tempURL
            }

            let fullFilename = sourceURL.lastPathComponent
            if let underscoreIndex = fullFilename.firstIndex(of: "_") {
                let messageId = String(fullFilename[..<underscoreIndex])
                guard !messageId.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
                let data = try await InlineAttachmentRecovery.shared.recoverData(messageId: messageId)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("preview_\(UUID().uuidString)")
                    .appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: tempURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: tempURL)
                return tempURL
            }

            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }

        let loader = RemoteAttachmentLoader()
        let loaded = try await loader.loadAttachmentData(from: key)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try loaded.data.write(to: tempURL)
        return tempURL
    }
}

final class FileAttachmentQuickLookPresenter: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    private let fileURL: URL
    private weak var presenter: UIViewController?

    init(fileURL: URL, presenter: UIViewController) {
        self.fileURL = fileURL
        self.presenter = presenter
    }

    @MainActor
    func present() {
        let previewController = QLPreviewController()
        previewController.dataSource = self
        previewController.delegate = self
        presenter?.present(previewController, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        fileURL as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        FileAttachmentQuickLookCoordinator.shared.release(self)
    }
}

@MainActor
final class FileAttachmentQuickLookCoordinator {
    static let shared: FileAttachmentQuickLookCoordinator = .init()

    private var presenters: [ObjectIdentifier: FileAttachmentQuickLookPresenter] = [:]

    func present(fileURL: URL, from presenter: UIViewController) {
        let quickLookPresenter = FileAttachmentQuickLookPresenter(fileURL: fileURL, presenter: presenter)
        let id = ObjectIdentifier(quickLookPresenter)
        presenters[id] = quickLookPresenter
        quickLookPresenter.present()
    }

    func release(_ presenter: FileAttachmentQuickLookPresenter) {
        presenters.removeValue(forKey: ObjectIdentifier(presenter))
    }
}
