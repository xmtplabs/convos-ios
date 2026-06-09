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
    public static func configure(with optionsURL: URL, debugToken: String? = nil, forceDebugProvider: Bool = false) {
        guard let options = FirebaseOptions(contentsOfFile: optionsURL.path) else { return }
        // App Attest is unavailable inside app extensions ("AppAttestProvider is
        // not supported on current platform"), so contexts like the share
        // extension force the debug provider with a registered debug token.
        var useDebugProvider: Bool = forceDebugProvider
        #if targetEnvironment(simulator)
        useDebugProvider = true
        #endif
        if useDebugProvider {
            // Pin the App Check debug token in UserDefaults so this process uses the
            // same registered token instead of the random UUID that AppCheckCore
            // generates and persists on first launch. Setting the FIRAAppCheckDebugToken
            // env var with `setenv` at this point doesn't work — AppCheckCore reads
            // NSProcessInfo.environment, a snapshot taken at process start.
            if let token = debugToken, !token.isEmpty {
                UserDefaults.standard.set(token, forKey: "GACAppCheckDebugToken")
            }
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        } else {
            AppCheck.setAppCheckProviderFactory(AppAttestFactory())
        }
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
