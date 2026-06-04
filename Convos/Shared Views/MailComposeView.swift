import MessageUI
import SwiftUI

/// SwiftUI wrapper around the system mail compose sheet, used by support
/// flows that need to attach files (mailto: links cannot carry attachments).
/// Check `MailComposeView.canSendMail` before presenting and fall back to a
/// mailto: link when no mail account is configured.
///
/// Attachments are passed pre-loaded so callers can read the file off the
/// main thread before presenting (large log bundles would otherwise stall
/// the sheet animation).
struct MailComposeView: UIViewControllerRepresentable {
    struct Attachment: Sendable {
        let data: Data
        let mimeType: String
        let fileName: String

        init?(contentsOf url: URL) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            self.data = data
            self.mimeType = url.mailAttachmentMimeType
            self.fileName = url.lastPathComponent
        }
    }

    let recipients: [String]
    let subject: String
    let attachment: Attachment?

    @Environment(\.dismiss) private var dismiss: DismissAction

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        if let attachment {
            controller.addAttachmentData(
                attachment.data,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}

private extension URL {
    var mailAttachmentMimeType: String {
        switch pathExtension.lowercased() {
        case "zip": "application/zip"
        case "json": "application/json"
        case "log", "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
