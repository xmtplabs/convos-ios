import AVFoundation
import SwiftUI

@MainActor
@Observable
class QRScannerViewModel: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var scannedCode: String?
    var cameraAuthorized: Bool = false
    var cameraSetupCompleted: Bool = false
    var isScanningEnabled: Bool = true
    var showInvalidInviteCodeFormat: Bool = false
    var invalidInviteCode: String?
    var presentingInvalidInviteSheet: Bool = false

    // Minimum time to wait before allowing another scan (in seconds)
    private let minimumScanInterval: TimeInterval = 3.0
    private var lastScanTime: Date?

    // callback for camera setup - set by QRScannerView
    var setupCameraCallback: (() -> Void)?

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.cameraAuthorized = granted
                if granted {
                    self?.triggerCameraSetup()
                }
            }
        }
    }

    /// Triggers camera setup if the callback is available (called when camera becomes authorized)
    func triggerCameraSetup() {
        setupCameraCallback?()
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Extract string value before entering MainActor context (AVMetadataObject is not Sendable)
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else { return }

        Task { @MainActor in
            // Only process if scanning is enabled and we're not showing an error
            guard isScanningEnabled else { return }

            guard !presentingInvalidInviteSheet else { return }

            // Check if enough time has passed since the last scan
            let now = Date()
            if let lastScan = lastScanTime {
                let timeSinceLastScan = now.timeIntervalSince(lastScan)
                guard timeSinceLastScan >= minimumScanInterval else { return }
            }

            lastScanTime = now

            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            scannedCode = stringValue

            // Disable further scanning after detecting a code
            isScanningEnabled = false
        }
    }

    func resetScanning() {
        isScanningEnabled = true
        scannedCode = nil
        // Note: we intentionally do NOT reset lastScanTime here
        // to maintain the minimum interval even across resets
    }

    func resetScanTimer() {
        lastScanTime = nil
    }
}
