#if canImport(UIKit)
import SwiftUI
import UIKit

public struct CameraPickerView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    let onVideoCaptured: ((URL) -> Void)?

    public init(onImageCaptured: @escaping (UIImage) -> Void, onVideoCaptured: ((URL) -> Void)? = nil) {
        self.onImageCaptured = onImageCaptured
        self.onVideoCaptured = onVideoCaptured
    }

    public static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    @Environment(\.dismiss) private var dismiss: DismissAction

    public func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, onVideoCaptured: onVideoCaptured, dismiss: dismiss)
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        guard Self.isAvailable else {
            let controller = UIViewController()
            DispatchQueue.main.async {
                self.dismiss()
            }
            return controller
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = onVideoCaptured != nil ? ["public.image", "public.movie"] : ["public.image"]
        picker.videoMaximumDuration = 60
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_: UIViewController, context _: Context) {}

    public final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void
        let onVideoCaptured: ((URL) -> Void)?
        let dismiss: DismissAction

        init(onImageCaptured: @escaping (UIImage) -> Void, onVideoCaptured: ((URL) -> Void)?, dismiss: DismissAction) {
            self.onImageCaptured = onImageCaptured
            self.onVideoCaptured = onVideoCaptured
            self.dismiss = dismiss
        }

        public func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let mediaType = info[.mediaType] as? String, mediaType == "public.movie",
               let videoURL = info[.mediaURL] as? URL {
                onVideoCaptured?(videoURL)
            } else if let image = info[.originalImage] as? UIImage {
                onImageCaptured(image)
            }
            dismiss()
        }

        public func imagePickerControllerDidCancel(_: UIImagePickerController) {
            dismiss()
        }
    }
}
#endif
