import ConvosAppData
import CryptoKit
import Foundation
import os

/// Parameters needed to download and decrypt an encrypted image
public struct EncryptedImageParams: Sendable {
    /// URL to the encrypted ciphertext (typically S3)
    public let url: URL
    /// 32-byte HKDF salt
    public let salt: Data
    /// 12-byte AES-GCM nonce
    public let nonce: Data
    /// 32-byte group encryption key
    public let groupKey: Data

    public init(url: URL, salt: Data, nonce: Data, groupKey: Data) {
        self.url = url
        self.salt = salt
        self.nonce = nonce
        self.groupKey = groupKey
    }

    /// Initialize from an EncryptedImageRef and group key
    /// - Parameters:
    ///   - encryptedRef: Reference containing URL, salt, and nonce
    ///   - groupKey: Group encryption key (from ConversationCustomMetadata.imageEncryptionKey)
    /// - Returns: nil if ref is invalid or groupKey is nil
    public init?(encryptedRef: EncryptedImageRef, groupKey: Data?) {
        guard let groupKey,
              encryptedRef.isValid,
              let url = URL(string: encryptedRef.url) else {
            return nil
        }
        self.url = url
        self.salt = encryptedRef.salt
        self.nonce = encryptedRef.nonce
        self.groupKey = groupKey
    }
}

/// Whose latency budget an encrypted-image fetch belongs to. Interactive and
/// background fetches are gated by separate concurrency limits so a burst of
/// sync-driven prefetches can never queue ahead of a fetch the UI is
/// blocked on.
public enum EncryptedImageFetchPriority: Sendable {
    /// A fetch the user is waiting on (cold cache miss for something on screen)
    case interactive
    /// Sync/prefetch work; the user is not blocked on it
    case background
}

/// Thrown when a fetch is refused because the URL previously failed
/// deterministically (oversized payload, decryption failure, undecodable
/// bytes). Encrypted assets are immutable blobs - a re-uploaded image gets a
/// new URL - so a deterministic failure for a URL can never heal and
/// refetching it only wastes bandwidth.
public struct EncryptedImageKnownBadURL: Error {}

/// Utility for downloading and decrypting encrypted images
public enum EncryptedImageLoader {
    /// Per-priority caps on concurrent encrypted-image downloads. Sync can
    /// schedule one fetch per conversation/profile in a burst; without a
    /// bound those all hold ciphertext and plaintext buffers at once, which
    /// is enough to exhaust the background memory budget. Separate gates
    /// keep user-blocking fetches out of the background queue.
    private static let interactiveGate: AsyncSemaphore = AsyncSemaphore(width: 4)
    private static let backgroundGate: AsyncSemaphore = AsyncSemaphore(width: 4)

    /// URLs whose fetch failed deterministically this process lifetime. The
    /// same URL always yields the same ciphertext and the same key material,
    /// so retrying cannot change the outcome; without this memory every
    /// avatar render and sync pass refires the download.
    private static let knownBadURLs: OSAllocatedUnfairLock<Set<String>> = OSAllocatedUnfairLock(initialState: [])

    /// The production transport: streams the payload to a temporary file so
    /// the encoded bytes are never fully buffered in memory.
    private static let urlSessionTransport: DownloadTransport = { url in
        try await URLSession.shared.download(from: url)
    }

    /// The production size probe: a HEAD request, so an oversized asset is
    /// rejected for the cost of one header round trip instead of a full
    /// download. Returns -1 when the server does not report a length.
    private static let urlSessionSizeProbe: SizeProbe = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.expectedContentLength
    }

    /// Downloads a URL to a temporary file and returns its location plus the
    /// response. Injectable so tests can drive error paths and concurrency
    /// without a live network.
    typealias DownloadTransport = @Sendable (URL) async throws -> (URL, URLResponse)

    /// Reports the expected payload size for a URL (-1 when unknown).
    /// Injectable so tests can drive the preflight without a live network.
    typealias SizeProbe = @Sendable (URL) async throws -> Int64

    /// Download ciphertext from URL and decrypt using provided parameters
    /// - Parameters:
    ///   - params: Encryption parameters including URL and crypto values
    ///   - priority: Which concurrency budget the fetch belongs to
    /// - Returns: Decrypted image data
    /// - Throws: `EncryptedImageKnownBadURL` without touching the network when
    ///   the URL previously failed deterministically; otherwise network errors
    ///   or `ImageEncryptionError` on decryption failure
    public static func loadAndDecrypt(
        params: EncryptedImageParams,
        priority: EncryptedImageFetchPriority = .background
    ) async throws -> Data {
        try await loadAndDecrypt(
            params: params,
            priority: priority,
            transport: urlSessionTransport,
            sizeProbe: urlSessionSizeProbe
        )
    }

    static func loadAndDecrypt(
        params: EncryptedImageParams,
        priority: EncryptedImageFetchPriority,
        transport: @escaping DownloadTransport,
        sizeProbe: @escaping SizeProbe = { _ in -1 }
    ) async throws -> Data {
        let urlKey = params.url.absoluteString
        guard !isKnownBadURL(urlKey) else {
            throw EncryptedImageKnownBadURL()
        }
        do {
            return try await gate(for: priority).withSlot {
                // Best-effort preflight: a failed probe falls through to the
                // download, where the post-download size check still guards.
                let expectedBytes: Int64 = (try? await sizeProbe(params.url)) ?? -1
                guard expectedBytes <= Int64(Constant.maxCiphertextBytes) else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                let (fileURL, response) = try await transport(params.url)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                return try decryptDownloadedFile(at: fileURL, response: response, params: params)
            }
        } catch {
            if isPermanentFailure(error) {
                markKnownBadURL(urlKey)
            }
            throw error
        }
    }

    /// Whether an error can never succeed on retry for the same URL:
    /// oversized payloads and cryptographic failures are functions of the
    /// immutable ciphertext and key material, unlike network errors.
    public static func isPermanentFailure(_ error: any Error) -> Bool {
        if error is EncryptedImageKnownBadURL { return true }
        if error is ImageEncryptionError { return true }
        if error is CryptoKitError { return true }
        if let urlError = error as? URLError, urlError.code == .dataLengthExceedsMaximum { return true }
        return false
    }

    /// Records a URL whose payload proved deterministically unusable (e.g.
    /// decrypted bytes that are not a decodable image). Subsequent fetches
    /// fail fast with `EncryptedImageKnownBadURL`.
    static func markKnownBadURL(_ urlKey: String) {
        knownBadURLs.withLock { _ = $0.insert(urlKey) }
    }

    static func isKnownBadURL(_ urlKey: String) -> Bool {
        knownBadURLs.withLock { $0.contains(urlKey) }
    }

    /// Validates the response and ciphertext size, then decrypts from a
    /// memory-mapped read of the downloaded file. Peak footprint per download
    /// is the plaintext only, instead of ciphertext + plaintext. Internal so
    /// the size and status error paths are testable without a network.
    static func decryptDownloadedFile(
        at fileURL: URL,
        response: URLResponse,
        params: EncryptedImageParams
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= Constant.maxCiphertextBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let ciphertext = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try ImageEncryption.decrypt(
            ciphertext: ciphertext,
            groupKey: params.groupKey,
            salt: params.salt,
            nonce: params.nonce
        )
    }

    private static func gate(for priority: EncryptedImageFetchPriority) -> AsyncSemaphore {
        switch priority {
        case .interactive: return interactiveGate
        case .background: return backgroundGate
        }
    }

    /// Convenience method with individual parameters
    public static func loadAndDecrypt(
        url: URL,
        salt: Data,
        nonce: Data,
        groupKey: Data,
        priority: EncryptedImageFetchPriority = .background
    ) async throws -> Data {
        let params = EncryptedImageParams(url: url, salt: salt, nonce: nonce, groupKey: groupKey)
        return try await loadAndDecrypt(params: params, priority: priority)
    }

    private enum Constant {
        /// Refuse ciphertext payloads larger than this. Avatars and group
        /// images are compressed to well under 1MB by the upload pipeline,
        /// so anything beyond this is not a legitimate image payload.
        static let maxCiphertextBytes: Int = 20 * 1024 * 1024
    }
}

/// Protocol for encrypted image loading (enables mocking in tests)
public protocol EncryptedImageLoaderProtocol: Sendable {
    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data
}

/// Default implementation of EncryptedImageLoaderProtocol
public final class EncryptedImageLoaderInstance: EncryptedImageLoaderProtocol, Sendable {
    public static let shared: any EncryptedImageLoaderProtocol = EncryptedImageLoaderInstance()

    public init() {}

    public func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        try await EncryptedImageLoader.loadAndDecrypt(params: params)
    }
}
