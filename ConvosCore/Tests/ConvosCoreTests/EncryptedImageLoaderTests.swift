@testable import ConvosCore
import Foundation
import Testing

private func makeTempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("encrypted-loader-test-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

private func makeHTTPResponse(statusCode: Int) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://example.com/image"))
    return try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
}

private func makeParams(salt: Data = Data(count: 32), nonce: Data = Data(count: 12), groupKey: Data = Data(count: 32)) throws -> EncryptedImageParams {
    let url = try #require(URL(string: "https://example.com/image"))
    return EncryptedImageParams(url: url, salt: salt, nonce: nonce, groupKey: groupKey)
}

struct EncryptedImageLoaderDecryptTests {
    @Test func roundTripDecryptsDownloadedFile() throws {
        let original = Data("the plaintext image bytes".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()
        let payload = try ImageEncryption.encrypt(imageData: original, groupKey: groupKey)
        let fileURL = try makeTempFile(payload.ciphertext)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let params = try makeParams(salt: payload.salt, nonce: payload.nonce, groupKey: groupKey)

        let plaintext = try EncryptedImageLoader.decryptDownloadedFile(
            at: fileURL,
            response: makeHTTPResponse(statusCode: 200),
            params: params
        )

        #expect(plaintext == original)
    }

    @Test func rejectsOversizedCiphertext() throws {
        // One byte past the loader's 20MB ciphertext cap
        let oversized = Data(count: 20 * 1024 * 1024 + 1)
        let fileURL = try makeTempFile(oversized)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let response = try makeHTTPResponse(statusCode: 200)
        let params = try makeParams()

        #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try EncryptedImageLoader.decryptDownloadedFile(at: fileURL, response: response, params: params)
        }
    }

    @Test func rejectsNon2xxResponse() throws {
        let fileURL = try makeTempFile(Data(count: 64))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let response = try makeHTTPResponse(statusCode: 500)
        let params = try makeParams()

        #expect(throws: URLError(.badServerResponse)) {
            try EncryptedImageLoader.decryptDownloadedFile(at: fileURL, response: response, params: params)
        }
    }

    @Test func rejectsNonHTTPResponse() throws {
        let fileURL = try makeTempFile(Data(count: 64))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let url = try #require(URL(string: "https://example.com/image"))
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        let params = try makeParams()

        #expect(throws: URLError(.badServerResponse)) {
            try EncryptedImageLoader.decryptDownloadedFile(at: fileURL, response: response, params: params)
        }
    }
}

/// Tracks how many transports are in flight at once.
private actor TransportCounter {
    private(set) var current: Int = 0
    private(set) var peak: Int = 0
    private(set) var completed: Int = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
        completed += 1
    }
}

/// A gate the test holds closed until it wants blocked transports to finish.
private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// The loader's gates are process-wide statics, so these tests must not run
/// concurrently with each other.
@Suite(.serialized)
struct EncryptedImageLoaderGateTests {
    @Test func backgroundDownloadsAreCappedAtFour() async throws {
        let counter = TransportCounter()
        let params = try makeParams()
        let transport: EncryptedImageLoader.DownloadTransport = { _ in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await counter.exit()
            throw URLError(.cancelled)
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try? await EncryptedImageLoader.loadAndDecrypt(params: params, priority: .background, transport: transport)
                }
            }
        }

        #expect(await counter.peak <= 4)
        #expect(await counter.completed == 12)
    }

    @Test func interactiveFetchDoesNotQueueBehindBackgroundBacklog() async throws {
        let params = try makeParams()
        let latch = TestLatch()
        let backgroundCounter = TransportCounter()
        let backgroundTransport: EncryptedImageLoader.DownloadTransport = { _ in
            await backgroundCounter.enter()
            await latch.wait()
            await backgroundCounter.exit()
            throw URLError(.cancelled)
        }

        // Saturate the background gate (4 holding slots, 4 queued behind them).
        let backgroundTasks = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        _ = try? await EncryptedImageLoader.loadAndDecrypt(params: params, priority: .background, transport: backgroundTransport)
                    }
                }
            }
        }

        // Wait until all four background slots are actually held.
        while await backgroundCounter.current < 4 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // An interactive fetch must complete while the background gate is
        // saturated; before the priority split it would queue behind all 8.
        let interactiveTransport: EncryptedImageLoader.DownloadTransport = { _ in
            throw URLError(.cancelled)
        }
        _ = try? await EncryptedImageLoader.loadAndDecrypt(params: params, priority: .interactive, transport: interactiveTransport)

        // Background work is still parked: nothing has completed.
        #expect(await backgroundCounter.completed == 0)

        await latch.open()
        await backgroundTasks.value
        #expect(await backgroundCounter.completed == 8)
    }
}
