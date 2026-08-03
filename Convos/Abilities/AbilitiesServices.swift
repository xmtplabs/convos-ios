import ConvosCore

/// Shared service instance backing the flag-gated V2 abilities surfaces
/// (the App Settings abilities list and the per-conversation abilities
/// section). Mock-backed until the live transport lands; one instance
/// app-wide so state changes carry across surfaces (connecting an ability
/// in settings is immediately visible in conversation info).
enum AbilitiesServices {
    static let shared: any AbilitiesServiceProtocol = MockAbilitiesService()
}
