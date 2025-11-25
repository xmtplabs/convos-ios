import PhotosUI
import SwiftUI

enum ImagePickerImageError: Error {
    case importFailed
}

struct ImagePickerImage: Transferable {
    enum State {
        case loading, empty, success(UIImage), failure(Error)
        var isEmpty: Bool {
            if case .empty = self {
                true
            } else {
                false
            }
        }
    }

    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let uiImage = UIImage(data: data) else {
                throw ImagePickerImageError.importFailed
            }
            return ImagePickerImage(image: uiImage)
        }
    }
}

extension PhotosPickerItem {
    @MainActor
    func loadImage() async -> ImagePickerImage.State {
        do {
            if let imagePickerImage = try await loadTransferable(type: ImagePickerImage.self) {
                return .success(imagePickerImage.image)
            } else {
                return .empty
            }
        } catch {
            return .failure(error)
        }
    }
}

struct ImagePickerButton: View {
    @Binding var currentImage: UIImage?
    var isPickerPresented: Binding<Bool>?
    @State var showsCurrentImage: Bool = true
    @State var imageState: ImagePickerImage.State = .empty
    @State var symbolSize: CGFloat = 24.0
    @State private var imageLoadingTask: Task<Void, Never>?
    @State private var imageSelection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(
            selection: $imageSelection,
            matching: .images,
            photoLibrary: .shared()
        ) {
            if imageState.isEmpty || !showsCurrentImage {
                if let currentImage = currentImage, showsCurrentImage {
                    Image(uiImage: currentImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle()
                            .fill(.black)
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: symbolSize))
                            .foregroundColor(.white)
                    }
                }
            } else {
                switch imageState {
                case .loading:
                    ProgressView()
                case .failure:
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text("Error loading image")
                            .font(.caption)
                            .foregroundColor(.red)
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
        .simultaneousGesture(TapGesture().onEnded {
            isPickerPresented?.wrappedValue = true
        })
        .onChange(of: imageSelection) { _, newValue in
            isPickerPresented?.wrappedValue = false
            if let imageSelection = newValue {
                imageLoadingTask?.cancel()
                imageLoadingTask = Task {
                    await loadSelectedImage(imageSelection)
                }
            }
        }
    }

    private func loadSelectedImage(_ imageSelection: PhotosPickerItem) async {
        let imageState = await imageSelection.loadImage()
        await MainActor.run {
            withAnimation {
                self.imageState = imageState
                if case .success(let image) = imageState {
                    self.currentImage = image
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var image: UIImage?
    VStack {
        ImagePickerButton(currentImage: $image)
            .frame(width: 52.0, height: 52.0)

        ImagePickerButton(currentImage: $image, showsCurrentImage: false)
            .frame(width: 52.0, height: 52.0)
    }
}
