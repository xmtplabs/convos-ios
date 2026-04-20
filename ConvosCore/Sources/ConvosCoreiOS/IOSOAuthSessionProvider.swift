#if canImport(UIKit)
import AuthenticationServices
import ConvosCore
import Foundation
import UIKit

public final class IOSOAuthSessionProvider: OAuthSessionProvider, @unchecked Sendable {
    public init() {}

    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
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

            session.prefersEphemeralWebBrowserSession = false

            DispatchQueue.main.async {
                session.presentationContextProvider = OAuthPresentationContextProvider.shared
                session.start()
            }
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
