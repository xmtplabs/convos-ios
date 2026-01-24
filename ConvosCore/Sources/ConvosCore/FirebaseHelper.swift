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
            // Set fixed debug token if provided (prevents auto-generation each simulator run)
            // Firebase checks the FIRAAppCheckDebugToken environment variable
            if let token = debugToken, !token.isEmpty {
                setenv("FIRAAppCheckDebugToken", token, 1)
                Log.debug("Set fixed App Check debug token env var: \(token.prefix(8))...")
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
