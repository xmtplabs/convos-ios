import FirebaseAppCheck
import FirebaseCore
import Foundation

public enum FirebaseHelperCore {
    /// Configures Firebase with the given options URL and optional debug token.
    /// - Parameters:
    ///   - optionsURL: URL to the GoogleService-Info.plist file
    ///   - debugToken: Optional fixed debug token for App Check (simulator only, non-production)
    ///                 When provided, this token is used instead of auto-generating a new one.
    ///                 This allows developers to pre-register a single token in Firebase Console.
    public static func configure(with optionsURL: URL, debugToken: String? = nil) {
        guard let options = FirebaseOptions(contentsOfFile: optionsURL.path) else { return }
        #if targetEnvironment(simulator)
            // Pin the App Check debug token in UserDefaults so every simulator run uses the
            // same registered token instead of the random UUID that AppCheckCore generates
            // and persists on first launch. Setting the FIRAAppCheckDebugToken env var with
            // `setenv` at this point doesn't work — AppCheckCore reads NSProcessInfo.environment,
            // which is a snapshot taken at process start and is unaffected by later setenv calls.
            if let token = debugToken, !token.isEmpty {
                UserDefaults.standard.set(token, forKey: "GACAppCheckDebugToken")
            }
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
            AppCheck.setAppCheckProviderFactory(AppAttestFactory())
        #endif
        FirebaseApp.configure(options: options)
        Log.info("Firebase configured for current environment: \(FirebaseApp.app()?.options.googleAppID ?? "undefined")")
    }

    public static func getAppCheckToken(forceRefresh: Bool = false) async throws -> String {
        let result = try await AppCheck.appCheck().token(forcingRefresh: forceRefresh)
        return result.token
    }
}

final class AppAttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
