import Foundation

class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []
    private static let lock: NSLock = NSLock()

    static var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    static func install(handler: @escaping Handler) {
        lock.withLock {
            storedRequests = []
            self.handler = handler
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            storedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> Handler? in
            Self.storedRequests.append(request)
            return Self.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: AgentRelayTestError.expected)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
