import PencilKit
import SwiftUI
import UIKit

struct WhiteboardView: UIViewControllerRepresentable {
    let onImageCreated: (UIImage) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCreated: onImageCreated, onCancel: onCancel, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let canvasController = WhiteboardViewController()
        canvasController.coordinator = context.coordinator
        let navigationController = UINavigationController(rootViewController: canvasController)
        navigationController.modalPresentationStyle = .fullScreen
        return navigationController
    }

    func updateUIViewController(_: UINavigationController, context _: Context) {}

    final class Coordinator {
        let onImageCreated: (UIImage) -> Void
        let onCancel: () -> Void
        let dismiss: DismissAction

        init(
            onImageCreated: @escaping (UIImage) -> Void,
            onCancel: @escaping () -> Void,
            dismiss: DismissAction
        ) {
            self.onImageCreated = onImageCreated
            self.onCancel = onCancel
            self.dismiss = dismiss
        }
    }
}

final class WhiteboardViewController: UIViewController {
    weak var coordinator: WhiteboardView.Coordinator?

    private let canvasView: PKCanvasView = {
        let view = PKCanvasView()
        view.backgroundColor = .white
        view.drawingPolicy = .anyInput
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let toolPicker: PKToolPicker = PKToolPicker()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        title = "Whiteboard"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(handleCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(handleDone)
        )

        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
    }

    @objc
    private func handleCancel() {
        guard !canvasView.drawing.strokes.isEmpty else {
            coordinator?.onCancel()
            coordinator?.dismiss()
            return
        }
        let alert = UIAlertController(
            title: "Discard drawing?",
            message: "Your drawing will be lost.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Keep editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.coordinator?.onCancel()
            self?.coordinator?.dismiss()
        })
        present(alert, animated: true)
    }

    @objc
    private func handleDone() {
        let drawing: PKDrawing = canvasView.drawing
        let scale: CGFloat = traitCollection.displayScale

        guard !drawing.strokes.isEmpty else {
            coordinator?.onCancel()
            coordinator?.dismiss()
            return
        }

        let padding: CGFloat = Constant.cropPadding
        let strokeBounds: CGRect = drawing.bounds.insetBy(dx: -padding, dy: -padding)
        let cropRect: CGRect = strokeBounds.intersection(canvasView.bounds)

        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        let image: UIImage = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: cropRect.size))
            drawing.image(from: cropRect, scale: scale).draw(at: .zero)
        }

        coordinator?.onImageCreated(image)
        coordinator?.dismiss()
    }

    private enum Constant {
        static let cropPadding: CGFloat = 32.0
    }
}
