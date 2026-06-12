@testable import ConvosCore
import Foundation
import Testing

@Suite("CreditsServices useRealBackend resolution")
struct CreditsServicesUseRealBackendTests {
    private static func makeDefaults() -> UserDefaults {
        let suiteName = "CreditsServicesUseRealBackendTests-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static var productionEnvironment: AppEnvironment {
        .production(config: ConvosConfiguration(
            apiBaseURL: "https://api.example.com",
            appGroupIdentifier: "group.test",
            relyingPartyIdentifier: "example.com",
            siweConfiguration: SIWEConfiguration(domain: "example.com", uri: "https://example.com", chainId: 1)
        ))
    }

    @Test("defaults to real backend when the toggle was never touched")
    func defaultsToRealBackend() {
        let defaults = Self.makeDefaults()
        #expect(CreditsServices.resolveUseRealBackend(environment: .tests, defaults: defaults) == true)
    }

    @Test("a stored OFF override persists in non-production environments")
    func storedOffOverridePersists() {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: CreditsServices.Constant.useRealBackendKey)
        #expect(CreditsServices.resolveUseRealBackend(environment: .tests, defaults: defaults) == false)
    }

    @Test("a stored ON override is honored in non-production environments")
    func storedOnOverrideHonored() {
        let defaults = Self.makeDefaults()
        defaults.set(true, forKey: CreditsServices.Constant.useRealBackendKey)
        #expect(CreditsServices.resolveUseRealBackend(environment: .tests, defaults: defaults) == true)
    }

    @Test("production ignores a stored OFF override and always uses the real backend")
    func productionIgnoresStoredOverride() {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: CreditsServices.Constant.useRealBackendKey)
        #expect(CreditsServices.resolveUseRealBackend(
            environment: Self.productionEnvironment,
            defaults: defaults
        ) == true)
    }
}
