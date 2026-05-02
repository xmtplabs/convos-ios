import PhotosUI
import SwiftUI

enum ImagePickerImageState {
    case loading
    case empty
    case success(UIImage)
    case failure(Error)

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

struct ImagePickerButton: View {
    @Binding var currentImage: UIImage?
    @Binding var isPickerPresented: Bool
    /// Optional binding for the underlying `PHAsset.localIdentifier` of `currentImage` when it
    /// originated from the photo library. Allows callers (e.g. `ProfileSettingsViewModel`) to
    /// detect when the user picked a different asset and to preselect the previously chosen one.
    var currentImageAssetIdentifier: Binding<String?>?
    @State var showsCurrentImage: Bool = true
    @State var imageState: ImagePickerImageState = .empty
    @State var symbolSize: CGFloat = 24.0
    let symbolName: String

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            buttonContent
        }
        .accessibilityLabel(currentImage != nil ? "Change photo" : "Choose photo")
        .accessibilityIdentifier("image-picker-button")
        .sheet(isPresented: $isPickerPresented) {
            PhotoLibraryPicker(
                preselectedAssetIdentifier: currentImageAssetIdentifier?.wrappedValue,
                onSelection: handleSelection,
                onCancel: { isPickerPresented = false }
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var buttonContent: some View {
        if imageState.isEmpty || !showsCurrentImage {
            if let currentImage, showsCurrentImage {
                Image(uiImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(.colorBackgroundInverted)
                    Image(systemName: symbolName)
                        .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                        .font(.system(size: symbolSize))
                        .foregroundColor(.colorTextPrimaryInverted)
                }
            }
        } else {
            switch imageState {
            case .loading:
                ProgressView()
            case .failure:
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.colorCaution)
                    Text("Error loading image")
                        .font(.caption)
                        .foregroundColor(.colorCaution)
                }
            case let .success(image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            case .empty:
                EmptyView()
            }
        }
    }

    private func handleSelection(image: UIImage, assetIdentifier: String?) {
        withAnimation {
            imageState = .success(image)
            currentImage = image
            currentImageAssetIdentifier?.wrappedValue = assetIdentifier
        }
        isPickerPresented = false
    }
}

/// `PHPickerViewController` wrapper that returns the picked image alongside its
/// `PHAsset.localIdentifier`, and supports preselecting the previously chosen asset.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let preselectedAssetIdentifier: String?
    let onSelection: (UIImage, String?) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        if let preselectedAssetIdentifier {
            config.preselectedAssetIdentifiers = [preselectedAssetIdentifier]
        }
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: (UIImage, String?) -> Void
        private let onCancel: () -> Void

        init(onSelection: @escaping (UIImage, String?) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                onCancel()
                return
            }
            let assetIdentifier = result.assetIdentifier
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                onCancel()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else {
                    DispatchQueue.main.async { [self] in onCancel() }
                    return
                }
                DispatchQueue.main.async { [self] in onSelection(image, assetIdentifier) }
            }
        }
    }
}

#Preview {
    @Previewable @State var image: UIImage?
    @Previewable @State var isPickerPresented: Bool = false
    VStack {
        ImagePickerButton(currentImage: $image, isPickerPresented: $isPickerPresented, symbolName: "photo.fill.on.rectangle.fill")
            .frame(width: 52.0, height: 52.0)
    }
}
