import ConvosCore
import QuickLook
import SwiftUI
import UIKit

struct QuickLookPreviewSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.fileURL = fileURL
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        var fileURL: URL
        let onDismiss: () -> Void

        init(fileURL: URL, onDismiss: @escaping () -> Void) {
            self.fileURL = fileURL
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            fileURL as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss()
        }
    }
}

private struct QuickLookSheetContainer: View {
    let fileURL: URL
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        QuickLookPreviewSheet(fileURL: fileURL) {
            onDismiss()
            dismiss()
        }
        .ignoresSafeArea()
    }
}

enum QuickLookSheetPresenter {
    @MainActor
    static func present(fileURL: URL, from presenter: UIViewController? = UIApplication.shared.topMostViewController()) {
        guard let presenter else { return }
        let host = UIHostingController(
            rootView: QuickLookSheetContainer(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
        )
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true)
    }
}

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
