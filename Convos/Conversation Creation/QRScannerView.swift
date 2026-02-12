@preconcurrency import AVFoundation
import SwiftUI

struct QRScannerView: UIViewRepresentable {
    let viewModel: QRScannerViewModel

    class Coordinator {
        var orientationObserver: Any?
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
        var captureDevice: AVCaptureDevice?
        var parentView: UIView?

        deinit {
            // Failsafe cleanup in case dismantleUIView wasn't called
            // Note: UI operations (like removeFromSuperlayer) must NOT be here
            // as deinit can run on any thread. All UI cleanup is in dismantleUIView.
            if let captureSession = captureSession, captureSession.isRunning {
                captureSession.stopRunning()

                // Clear metadata output delegates
                captureSession.outputs.forEach { output in
                    if let metadataOutput = output as? AVCaptureMetadataOutput {
                        metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
                    }
                }
            }

            if let observer = orientationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.accessibilityLabel = NSLocalizedString("QR code scanner camera view", comment: "")
        view.accessibilityIdentifier = "qr-scanner-camera"
        context.coordinator.parentView = view

        // Set up the internal callback for camera setup
        viewModel.setupCameraCallback = { [weak view, weak coordinator = context.coordinator] in
            guard let view = view, let coordinator = coordinator else { return }
            self.setupCamera(on: view, coordinator: coordinator)
        }

        // Check initial camera authorization
        checkCameraAuthorization { @MainActor [weak viewModel] authorized in
            viewModel?.cameraAuthorized = authorized
            if authorized {
                self.setupCamera(on: view, coordinator: context.coordinator)
            }
        }

        return view
    }

    private func checkCameraAuthorization(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .denied, .restricted, .notDetermined:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func setupCamera(on view: UIView, coordinator: Coordinator) {
        // Guard against duplicate initialization
        guard coordinator.captureSession == nil else {
            // If session already exists, just ensure it's running
            if let existingSession = coordinator.captureSession, !existingSession.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    existingSession.startRunning()
                }
            }
            return
        }

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            Log.info("Failed to get video capture device")
            return
        }

        let videoInput: AVCaptureDeviceInput

        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            Log.info("Failed to create video input: \(error)")
            return
        }

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            Log.info("Cannot add video input")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(viewModel, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            Log.info("Cannot add metadata output")
            return
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        // Use window bounds to fill entire screen including safe areas
        if let window = view.window {
            previewLayer.frame = window.bounds
        } else {
            previewLayer.frame = view.bounds
        }
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        // Set initial orientation
        updateVideoOrientation(for: previewLayer)

        // Store references in coordinator
        coordinator.captureSession = captureSession
        coordinator.previewLayer = previewLayer
        coordinator.captureDevice = videoCaptureDevice

        // Register for orientation notifications
        nonisolated(unsafe) let unsafePreviewLayer = previewLayer
        coordinator.orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Delay slightly to ensure view bounds are updated after rotation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Use window bounds to fill entire screen including safe areas
                if let window = view.window {
                    unsafePreviewLayer.frame = view.convert(window.bounds, from: window)
                } else {
                    unsafePreviewLayer.frame = view.bounds
                }
                CATransaction.commit()
                self.updateVideoOrientation(for: unsafePreviewLayer)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }

        // Mark camera setup as completed
        viewModel.cameraSetupCompleted = true
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Update preview layer frame
        if let previewLayer = context.coordinator.previewLayer {
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Use window bounds to fill entire screen including safe areas
                if let window = uiView.window {
                    previewLayer.frame = uiView.convert(window.bounds, from: window)
                } else {
                    previewLayer.frame = uiView.bounds
                }
                CATransaction.commit()
                self.updateVideoOrientation(for: previewLayer)
            }
        }
    }

    private func updateVideoOrientation(for previewLayer: AVCaptureVideoPreviewLayer) {
        guard let connection = previewLayer.connection else { return }

        let orientation = UIDevice.current.orientation

        // Map device orientation to video rotation angle
        // Note: Camera sensor is mounted in landscape, so portrait needs 90° rotation
        let rotationAngle: CGFloat

        switch orientation {
        case .portrait:
            rotationAngle = 90
        case .portraitUpsideDown:
            rotationAngle = 270
        case .landscapeLeft:
            // Device rotated left (home button on right)
            rotationAngle = 0
        case .landscapeRight:
            // Device rotated right (home button on left)
            rotationAngle = 180
        default:
            // For face up, face down, and unknown, try to use the interface orientation
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                switch windowScene.effectiveGeometry.interfaceOrientation {
                case .portrait:
                    rotationAngle = 90
                case .portraitUpsideDown:
                    rotationAngle = 270
                case .landscapeLeft:
                    rotationAngle = 180
                case .landscapeRight:
                    rotationAngle = 0
                default:
                    rotationAngle = 90
                }
            } else {
                rotationAngle = 90
            }
        }

        connection.videoRotationAngle = rotationAngle
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Stop the capture session immediately
        if let captureSession = coordinator.captureSession {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }

            // Remove all inputs and outputs
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            captureSession.outputs.forEach { output in
                // Clear the delegate before removing the output
                if let metadataOutput = output as? AVCaptureMetadataOutput {
                    metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
                }
                captureSession.removeOutput(output)
            }
        }

        // Remove preview layer
        coordinator.previewLayer?.removeFromSuperlayer()
        coordinator.previewLayer = nil

        // Clear all references
        coordinator.captureSession = nil
        coordinator.captureDevice = nil

        // Remove orientation observer
        if let observer = coordinator.orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.orientationObserver = nil
        }
    }
}
