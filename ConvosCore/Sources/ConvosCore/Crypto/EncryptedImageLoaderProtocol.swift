import Foundation

public protocol EncryptedImageLoaderProtocol: Sendable {
    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data
}
