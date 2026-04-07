import AVFoundation
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

        let locale = await pickLocale()
        guard let locale else {
            throw VoiceMemoTranscriberError.unsupportedLocale
        }

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

    private static func pickLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { return nil }

        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return equivalent
        }

        if let englishUS = supported.first(where: { $0.identifier == "en_US" }) {
            return englishUS
        }
        return supported.first
    }

    private static func ensureAssetsInstalled(for modules: [any SpeechModule]) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            } else {
                throw VoiceMemoTranscriberError.assetsUnavailable
            }
        case .unsupported:
            throw VoiceMemoTranscriberError.assetsUnavailable
        @unknown default:
            throw VoiceMemoTranscriberError.assetsUnavailable
        }
    }
}
