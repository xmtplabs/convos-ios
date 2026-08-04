import FirebaseAppCheck
import FirebaseCore
import Foundation

public enum FirebaseHelperCore {
    /// Set by app-extension processes. When present, `getAppCheckToken` prefers
    /// a fresh token the main app mirrored into this shared app group over the
    /// extension's own attestation - App Attest is unavailable in extensions,
    /// and the pinned debug token only exists in local developer builds, so an
    /// extension archive (PR preview, TestFlight, App Store) has no way to
    /// attest on its own.
    nonisolated(unsafe) public static var sharedTokenAppGroupIdentifier: String?

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
        if !forceRefresh,
           let appGroupIdentifier = sharedTokenAppGroupIdentifier,
           let sharedToken = SharedAppCheckTokenStore.load(appGroupIdentifier: appGroupIdentifier) {
            return sharedToken
        }
        guard FirebaseApp.app() != nil else {
            throw AppCheckTokenError.firebaseNotConfigured
        }
        let result = try await AppCheck.appCheck().token(forcingRefresh: forceRefresh)
        return result.token
    }

    /// Mints a limited-use (consumable) App Check token. Required by
    /// server routes that consume the attestation — e.g. the subscription
    /// claim endpoint. Never reuse one across attempts: a consumed token
    /// replays as invalid.
    public static func getLimitedUseAppCheckToken() async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw AppCheckTokenError.firebaseNotConfigured
        }
        let result = try await AppCheck.appCheck().limitedUseToken()
        return result.token
    }

    /// Mirrors this process's current App Check token into the shared app
    /// group so extension processes (which cannot App Attest) can authenticate
    /// against the backend. Called by the main app at launch and on
    /// foregrounding; `token(forcingRefresh: false)` returns the cached token
    /// when it is still valid, so repeated calls are cheap.
    public static func mirrorTokenToAppGroup(_ appGroupIdentifier: String) async {
        guard FirebaseApp.app() != nil else { return }
        do {
            let result = try await AppCheck.appCheck().token(forcingRefresh: false)
            SharedAppCheckTokenStore.store(
                token: result.token,
                expiration: result.expirationDate,
                appGroupIdentifier: appGroupIdentifier
            )
        } catch {
            Log.error("Failed to mirror App Check token to app group: \(error.localizedDescription)")
        }
    }
}

public enum AppCheckTokenError: Error {
    case firebaseNotConfigured
}

/// UserDefaults-backed handoff of the main app's App Check token to extension
/// processes in the same app group. Tokens are short-lived (about an hour), so
/// the store only vends tokens that are still comfortably within their window.
public enum SharedAppCheckTokenStore {
    public static func store(token: String, expiration: Date, appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(token, forKey: Constant.tokenKey)
        defaults.set(expiration.timeIntervalSince1970, forKey: Constant.expirationKey)
    }

    public static func load(appGroupIdentifier: String) -> String? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let token = defaults.string(forKey: Constant.tokenKey),
              !token.isEmpty else {
            return nil
        }
        let expiration = Date(timeIntervalSince1970: defaults.double(forKey: Constant.expirationKey))
        guard expiration > Date().addingTimeInterval(Constant.minimumRemainingLifetime) else {
            return nil
        }
        return token
    }

    private enum Constant {
        static let tokenKey: String = "appCheck.sharedToken"
        static let expirationKey: String = "appCheck.sharedTokenExpiration"
        static let minimumRemainingLifetime: TimeInterval = 60
    }
}

final class AppAttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
