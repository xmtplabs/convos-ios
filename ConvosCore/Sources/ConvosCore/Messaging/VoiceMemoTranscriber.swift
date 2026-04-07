import AVFoundation
import ConvosLogging
import Foundation
import Speech

/// Errors thrown by the voice memo transcription pipeline.
public enum VoiceMemoTranscriberError: Error, LocalizedError, Sendable {
    case authorizationDenied
    case unsupportedLocale
    case assetsUnavailable
    case audioFileUnreadable
    case emptyTranscript
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition is not authorized"
        case .unsupportedLocale:
            return "No supported locale for on-device transcription"
        case .assetsUnavailable:
            return "On-device speech models are not available"
        case .audioFileUnreadable:
            return "Unable to read voice memo audio"
        case .emptyTranscript:
            return "Speech recognizer produced an empty transcript"
        case .cancelled:
            return "Transcription was cancelled"
        }
    }

    /// Whether retrying transcription with the same audio is likely to fail again
    /// in the same way. Used by `VoiceMemoTranscriptionService` to decide whether
    /// to surface a failure row + retry button or to silently swallow the failure
    /// (so we don't lie to the user with a "Tap to try again" affordance that
    /// can never succeed).
    public var isPermanentFailure: Bool {
        switch self {
        case .assetsUnavailable, .unsupportedLocale:
            // The on-device speech model is not present and either cannot be
            // downloaded for this locale, or the device/simulator does not
            // support on-device speech at all. No amount of retrying will fix
            // this.
            return true
        case .authorizationDenied:
            // Recoverable only via Settings, but the in-app retry button does
            // not actually drive the user to Settings, so treat as permanent.
            return true
        case .emptyTranscript:
            // The audio decoded fine but contained no speech (silent recording,
            // background noise only, etc.). Retrying against the same audio
            // will produce the same empty result, so hide the cell entirely.
            return true
        case .audioFileUnreadable, .cancelled:
            return false
        }
    }
}

/// Abstraction around the on-device transcription pipeline so we can mock it in tests
/// and swap implementations if Apple updates the APIs.
public protocol VoiceMemoTranscribing: Sendable {
    /// Transcribes the audio file at `fileURL` on-device.
    ///
    /// - Parameter messageId: Used to deduplicate concurrent work for the same message.
    /// - Parameter fileURL: A local file URL pointing to a voice memo audio payload.
    /// - Returns: The plain-text transcript.
    func transcribe(messageId: String, fileURL: URL) async throws -> String

    /// Cancels an in-flight transcription for the given message if any.
    func cancel(messageId: String) async
}

/// On-device voice memo transcriber using Apple's `Speech` framework (`SpeechAnalyzer` +
/// `SpeechTranscriber`). Deduplicates concurrent work per message id so repeated UI
/// hydration does not schedule duplicate jobs.
public actor VoiceMemoTranscriber: VoiceMemoTranscribing {
    private var inFlight: [String: Task<String, Error>] = [:]

    public init() {}

    public func transcribe(messageId: String, fileURL: URL) async throws -> String {
        if let existing = inFlight[messageId] {
            return try await existing.value
        }

        let task = Task<String, Error> {
            try await Self.runTranscription(fileURL: fileURL)
        }
        inFlight[messageId] = task

        do {
            let result = try await task.value
            inFlight[messageId] = nil
            return result
        } catch {
            inFlight[messageId] = nil
            throw error
        }
    }

    public func cancel(messageId: String) async {
        if let task = inFlight.removeValue(forKey: messageId) {
            task.cancel()
        }
    }

    // MARK: - Private

    private static func runTranscription(fileURL: URL) async throws -> String {
        try await ensureAuthorized()

        let locale = try await pickLocale()
        Log.info("[VoiceMemoTranscription] Using locale \(locale.identifier) for transcription")

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )

        try await ensureAssetsInstalled(for: [transcriber])

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw VoiceMemoTranscriberError.audioFileUnreadable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collectionTask = Task { () -> String in
            var combined = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let fragment = String(result.text.characters)
                guard !fragment.isEmpty else { continue }
                if !combined.isEmpty, combined.last?.isWhitespace == false {
                    combined.append(" ")
                }
                combined.append(fragment)
            }
            return combined
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            collectionTask.cancel()
            throw error
        }

        let raw: String
        do {
            raw = try await collectionTask.value
        } catch is CancellationError {
            throw VoiceMemoTranscriberError.cancelled
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceMemoTranscriberError.emptyTranscript
        }
        return trimmed
    }

    private static func ensureAuthorized() async throws {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized:
            return
        case .denied, .restricted:
            throw VoiceMemoTranscriberError.authorizationDenied
        case .notDetermined:
            let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if granted != .authorized {
                throw VoiceMemoTranscriberError.authorizationDenied
            }
        @unknown default:
            throw VoiceMemoTranscriberError.authorizationDenied
        }
    }

    private static func pickLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        Log.info(
            "[VoiceMemoTranscription] supportedLocales=\(supported.count) installedLocales=\(installed.count) current=\(Locale.current.identifier)"
        )

        // 1. Prefer an installed locale that matches the user's current locale.
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return equivalent
        }

        // 2. Otherwise prefer any installed locale (avoids a model download).
        if let firstInstalled = installed.first {
            return firstInstalled
        }

        // 3. Otherwise prefer en-US from the supported set so the asset installer
        //    has a clear target.
        if let englishUS = supported.first(where: { $0.identifier.hasPrefix("en_US") || $0.identifier.hasPrefix("en-US") }) {
            return englishUS
        }

        // 4. Otherwise pick any supported locale.
        if let any = supported.first {
            return any
        }

        // 5. Last resort: hand-roll en-US. The asset installer will tell us if the
        //    speech model isn't actually available for this device.
        Log.warning("[VoiceMemoTranscription] No supported or installed locales reported by SpeechTranscriber; falling back to en-US")
        return Locale(identifier: "en_US")
    }

    private static func ensureAssetsInstalled(for modules: [any SpeechModule]) async throws {
        let status = await AssetInventory.status(forModules: modules)
        Log.info("[VoiceMemoTranscription] AssetInventory status: \(status)")
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    Log.info("[VoiceMemoTranscription] Downloading speech assets…")
                    try await request.downloadAndInstall()
                    Log.info("[VoiceMemoTranscription] Speech assets installed")
                } else {
                    Log.warning("[VoiceMemoTranscription] AssetInventory returned no installation request")
                    throw VoiceMemoTranscriberError.assetsUnavailable
                }
            } catch let error as VoiceMemoTranscriberError {
                throw error
            } catch {
                Log.error("[VoiceMemoTranscription] Asset installation failed: \(error)")
                throw VoiceMemoTranscriberError.assetsUnavailable
            }
        case .unsupported:
            Log.warning("[VoiceMemoTranscription] Speech model is unsupported on this device")
            throw VoiceMemoTranscriberError.assetsUnavailable
        @unknown default:
            throw VoiceMemoTranscriberError.assetsUnavailable
        }
    }
}
