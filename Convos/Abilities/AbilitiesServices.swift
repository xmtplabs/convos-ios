import ConvosCore

/// Shared service instance backing the flag-gated V2 abilities surfaces
/// (the App Settings abilities list and the per-conversation abilities
/// section). Mock-backed until the live transport lands; one instance
/// app-wide so state changes carry across surfaces (connecting an ability
/// in settings is immediately visible in conversation info).
enum AbilitiesServices {
    static let shared: any AbilitiesServiceProtocol = MockAbilitiesService()

    /// The browser-session authorizer paired with `shared`. Nil while the
    /// mock service is active (the stub authorization sheet stands in);
    /// the live service selection supplies the real
    /// `AbilityOAuthAuthorizer`.
    static var oauthAuthorizer: (any AbilityAuthorizing)? { nil }
}
