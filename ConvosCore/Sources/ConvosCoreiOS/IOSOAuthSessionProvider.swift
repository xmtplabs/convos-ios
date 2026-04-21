#if canImport(UIKit)
@preconcurrency import AuthenticationServices
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

            // Resumption is guarded so neither start()==false nor a late completion
            // callback can resume twice. NSLock is enough — the state transitions are
            // trivial and the guard runs off the main thread from the completion path.
            let resumeLock = NSLock()
            nonisolated(unsafe) var didResume = false
            let tryResume: (Result<URL, Error>) -> Void = { result in
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                if let sessionKey {
                    self?.releaseSession(key: sessionKey)
                }

                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        tryResume(.failure(OAuthError.cancelled))
                    } else {
                        tryResume(.failure(OAuthError.failed(error)))
                    }
                    return
                }

                guard let callbackURL else {
                    tryResume(.failure(OAuthError.invalidCallbackURL))
                    return
                }

                tryResume(.success(callbackURL))
            }

            sessionKey = retainSession(session)
            session.prefersEphemeralWebBrowserSession = false

            DispatchQueue.main.async { [weak self] in
                session.presentationContextProvider = OAuthPresentationContextProvider.shared
                let started = session.start()
                guard !started else { return }

                // start() returns false without invoking the completion handler
                // (e.g. presentation context unavailable, another session already
                // running). Clean up and resume explicitly so the caller doesn't hang.
                if let sessionKey {
                    self?.releaseSession(key: sessionKey)
                }
                tryResume(.failure(OAuthError.failed(OAuthStartError.couldNotStart)))
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

enum OAuthStartError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Could not start the authentication session."
        }
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
