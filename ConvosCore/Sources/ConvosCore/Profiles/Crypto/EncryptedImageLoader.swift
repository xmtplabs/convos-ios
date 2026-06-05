import ConvosAppData
import Foundation

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

/// Utility for downloading and decrypting encrypted images
public enum EncryptedImageLoader {
    /// Per-priority caps on concurrent encrypted-image downloads. Sync can
    /// schedule one fetch per conversation/profile in a burst; without a
    /// bound those all hold ciphertext and plaintext buffers at once, which
    /// is enough to exhaust the background memory budget. Separate gates
    /// keep user-blocking fetches out of the background queue.
    private static let interactiveGate: AsyncSemaphore = AsyncSemaphore(width: 4)
    private static let backgroundGate: AsyncSemaphore = AsyncSemaphore(width: 4)

    /// The production transport: streams the payload to a temporary file so
    /// the encoded bytes are never fully buffered in memory.
    private static let urlSessionTransport: DownloadTransport = { url in
        try await URLSession.shared.download(from: url)
    }

    /// Downloads a URL to a temporary file and returns its location plus the
    /// response. Injectable so tests can drive error paths and concurrency
    /// without a live network.
    typealias DownloadTransport = @Sendable (URL) async throws -> (URL, URLResponse)

    /// Download ciphertext from URL and decrypt using provided parameters
    /// - Parameters:
    ///   - params: Encryption parameters including URL and crypto values
    ///   - priority: Which concurrency budget the fetch belongs to
    /// - Returns: Decrypted image data
    /// - Throws: Network errors or `ImageEncryptionError` on decryption failure
    public static func loadAndDecrypt(
        params: EncryptedImageParams,
        priority: EncryptedImageFetchPriority = .background
    ) async throws -> Data {
        try await loadAndDecrypt(params: params, priority: priority, transport: urlSessionTransport)
    }

    static func loadAndDecrypt(
        params: EncryptedImageParams,
        priority: EncryptedImageFetchPriority,
        transport: @escaping DownloadTransport
    ) async throws -> Data {
        try await gate(for: priority).withSlot {
            let (fileURL, response) = try await transport(params.url)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            return try decryptDownloadedFile(at: fileURL, response: response, params: params)
        }
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
