import Foundation

public protocol OAuthSessionProvider: Sendable {
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL
}

public enum OAuthError: LocalizedError {
    case cancelled
    case failed(Error)
    case invalidCallbackURL

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Authentication was cancelled"
        case .failed(let error):
            "Authentication failed: \(error.localizedDescription)"
        case .invalidCallbackURL:
            "Invalid callback URL received"
        }
    }
}
