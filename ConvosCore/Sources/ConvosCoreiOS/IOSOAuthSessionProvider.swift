#if canImport(UIKit)
import AuthenticationServices
import ConvosCore
import Foundation
import UIKit

public final class IOSOAuthSessionProvider: OAuthSessionProvider, @unchecked Sendable {
    // Apple's docs: the caller must retain the ASWebAuthenticationSession until its
    // completion handler is invoked. Without this, the session can be deallocated
    // after start() returns and the continuation hangs forever.
    private let sessionsLock: NSLock = NSLock()
    private var retainedSessions: [ObjectIdentifier: ASWebAuthenticationSession] = [:]

    public init() {}

    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var sessionKey: ObjectIdentifier?
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                if let sessionKey {
                    self?.releaseSession(key: sessionKey)
                }

                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.failed(error))
                    }
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidCallbackURL)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            sessionKey = retainSession(session)
            session.prefersEphemeralWebBrowserSession = false

            DispatchQueue.main.async {
                session.presentationContextProvider = OAuthPresentationContextProvider.shared
                session.start()
            }
        }
    }

    private func retainSession(_ session: ASWebAuthenticationSession) -> ObjectIdentifier {
        let key = ObjectIdentifier(session)
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        retainedSessions[key] = session
        return key
    }

    private func releaseSession(key: ObjectIdentifier) {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        retainedSessions.removeValue(forKey: key)
    }
}

private final class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared: OAuthPresentationContextProvider = OAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return UIWindow()
        }
        return scene.windows.first ?? UIWindow(windowScene: scene)
    }
}
#endif
