import Foundation

/// Mock implementation of EncryptedImageLoaderProtocol for testing
public final class MockEncryptedImageLoader: EncryptedImageLoaderProtocol, @unchecked Sendable {
    private var stubbedImages: [URL: Data] = [:]
    public private(set) var loadCalls: [EncryptedImageParams] = []

    public init() {}

    public func stub(url: URL, with imageData: Data) {
        stubbedImages[url] = imageData
    }

    public func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        loadCalls.append(params)

        guard let data = stubbedImages[params.url] else {
            throw URLError(.fileDoesNotExist)
        }

        return data
    }
}
